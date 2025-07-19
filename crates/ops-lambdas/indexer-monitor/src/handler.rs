// Copyright (c) 2025 RISC Zero, Inc.
//
// All rights reserved.

use std::str::FromStr;
use std::time::Duration;

use alloy::primitives::Address;
use anyhow::{Context, Result};
use aws_config::retry::{RetryConfigBuilder, RetryMode};
use aws_config::Region;
use aws_sdk_cloudwatch::types::{MetricDatum, StandardUnit};
use aws_sdk_cloudwatch::Client as CloudWatchClient;
use aws_smithy_types::retry::ReconnectMode;
use aws_smithy_types::DateTime;
use chrono::Utc;
use lambda_runtime::{Error, LambdaEvent};
use serde::Deserialize;
use std::env;
use tracing::{debug, instrument};

use crate::monitor::Monitor;

// We apply a lag to the metrics to avoid race conditions with the indexer,
// where the indexer might not have finished processing and publishing the events
// for time "now" before this lambda runs on time "now".
const METRIC_LAG_SECONDS: i64 = 60;

/// Incoming message structure for the Lambda event
#[derive(Deserialize, Debug)]
pub struct Event {
    pub clients: Vec<String>,
    pub provers: Vec<String>,
}

/// Lambda function configuration read from environment variables
struct Config {
    db_url: String,
    region: String,
    namespace: String,
}

impl Config {
    /// Load configuration from environment variables
    fn from_env() -> Result<Self, Error> {
        let db_url = env::var("DB_URL").context("DB_URL environment variable is required")?;

        let region = env::var("AWS_REGION").unwrap_or_else(|_| "us-west-2".to_string());

        let namespace =
            env::var("CLOUDWATCH_NAMESPACE").unwrap_or_else(|_| "indexer-monitor".to_string());

        Ok(Self { db_url, region, namespace })
    }
}

/// Helper function to debug log request counts only when count > 0
fn debug_requests_if_any(metric_time: &str, count: usize, requests: &[String], message: &str) {
    if count > 0 {
        debug!(metric_time, count, requests = ?requests, "{}", message);
    }
}

/// Main Lambda handler function
#[instrument(skip_all, err)]
pub async fn function_handler(event: LambdaEvent<Event>) -> Result<(), Error> {
    let config = Config::from_env()?;
    let event = event.payload;
    debug!(?event, "Lambda function started");

    let monitor = Monitor::new(&config.db_url).await.context("Failed to create monitor")?;

    let now = Utc::now().timestamp() - METRIC_LAG_SECONDS;
    let now_str = chrono::DateTime::from_timestamp(now, 0).unwrap().to_rfc3339();
    let start_time = monitor.get_last_run().await.context("Failed to get last run time")?;
    let start_time_str = chrono::DateTime::from_timestamp(start_time, 0).unwrap().to_rfc3339();

    let mut metrics = vec![];

    debug!(
        start_time,
        now, "Fetching metrics from {start_time_str} [{start_time}] to {now_str} [{now}]"
    );

    let expired = monitor
        .fetch_requests_expired(start_time, now)
        .await
        .context("Failed to fetch expired requests")?;

    let expired_count = expired.len();
    debug_requests_if_any(&now_str, expired_count, &expired, "Found expired request(s)");
    metrics.push(new_metric("expired_requests_number", expired_count as f64, now));

    let requests =
        monitor.fetch_requests(start_time, now).await.context("Failed to fetch requests number")?;
    let requests_count = requests.len();
    debug_requests_if_any(&now_str, requests_count, &requests, "Found request(s)");
    metrics.push(new_metric("requests_number", requests_count as f64, now));

    let fulfillments = monitor
        .fetch_fulfillments(start_time, now)
        .await
        .context("Failed to fetch fulfilled requests number")?;
    let fulfillment_count = fulfillments.len();
    debug_requests_if_any(&now_str, fulfillment_count, &fulfillments, "Found fulfilled request(s)");
    metrics.push(new_metric("fulfilled_requests_number", fulfillment_count as f64, now));

    let slashed = monitor
        .fetch_slashed(start_time, now)
        .await
        .context("Failed to fetch slashed requests number")?;
    let slashed_count = slashed.len();
    debug_requests_if_any(&now_str, slashed_count, &slashed, "Found slashed request(s)");
    metrics.push(new_metric("slashed_requests_number", slashed_count as f64, now));

    for client in event.clients {
        debug!(client, "Processing client {client}");
        let address = Address::from_str(&client).context("Failed to parse client address")?;

        let expired_requests = monitor
            .fetch_requests_expired_from(start_time, now, address)
            .await
            .context("Failed to fetch expired requests for client {client}")?;
        let expired_count = expired_requests.len();
        debug_requests_if_any(
            &now_str,
            expired_count,
            &expired_requests,
            &format!("Found expired request(s) for client {client}"),
        );
        metrics.push(new_metric(
            &format!("expired_requests_number_from_{client}"),
            expired_count as f64,
            now,
        ));

        let requests = monitor
            .fetch_requests_from_client(start_time, now, address)
            .await
            .context("Failed to fetch requests number for client {client}")?;
        let requests_count = requests.len();
        debug_requests_if_any(
            &now_str,
            requests_count,
            &requests,
            &format!("Found request(s) for client {client}"),
        );
        metrics.push(new_metric(
            &format!("requests_number_from_{client}"),
            requests_count as f64,
            now,
        ));

        let fulfilled = monitor
            .fetch_fulfillments_from_client(start_time, now, address)
            .await
            .context("Failed to fetch fulfilled requests number for client {client}")?;
        let fulfilled_count = fulfilled.len();
        debug_requests_if_any(
            &now_str,
            fulfilled_count,
            &fulfilled,
            &format!("Found fulfilled request(s) for client {client}"),
        );
        metrics.push(new_metric(
            &format!("fulfilled_requests_number_from_{client}"),
            fulfilled_count as f64,
            now,
        ));
    }

    for prover in event.provers {
        debug!(prover, "Processing prover {prover}");

        let address = Address::from_str(&prover).context("Failed to parse prover address")?;

        let fulfilled = monitor
            .fetch_fulfillments_by_prover(start_time, now, address)
            .await
            .context("Failed to fetch fulfilled requests number by prover {prover}")?;
        let fulfilled_count = fulfilled.len();
        debug_requests_if_any(
            &now_str,
            fulfilled_count,
            &fulfilled,
            &format!("Found fulfilled request(s) for prover {prover}"),
        );
        metrics.push(new_metric(
            &format!("fulfilled_requests_number_by_{prover}"),
            fulfilled_count as f64,
            now,
        ));

        let locked = monitor
            .fetch_locked_by_prover(start_time, now, address)
            .await
            .context("Failed to fetch locked requests number by prover {prover}")?;
        let locked_count = locked.len();
        debug_requests_if_any(
            &now_str,
            locked_count,
            &locked,
            &format!("Found locked request(s) for prover {prover}"),
        );
        metrics.push(new_metric(
            &format!("locked_requests_number_by_{prover}"),
            locked_count as f64,
            now,
        ));

        let slashed = monitor
            .fetch_slashed_by_prover(start_time, now, address)
            .await
            .context("Failed to fetch slashed requests number by prover {prover}")?;
        let slashed_count = slashed.len();
        debug_requests_if_any(
            &now_str,
            slashed_count,
            &slashed,
            &format!("Found slashed request(s) for prover {prover}"),
        );
        metrics.push(new_metric(
            &format!("slashed_requests_number_by_{prover}"),
            slashed_count as f64,
            now,
        ));
    }

    debug!(metric_time = now_str, "Publishing metrics to CloudWatch with time: {now_str}");
    publish_metric(&config.region, &config.namespace, metrics).await?;

    debug!("Updating last run time: {now}");
    monitor.set_last_run(now).await.context("Failed to update last run time")?;

    Ok(())
}

fn new_metric(name: &str, value: f64, timestamp: i64) -> MetricDatum {
    MetricDatum::builder()
        .metric_name(name)
        .timestamp(DateTime::from_secs(timestamp))
        .unit(StandardUnit::Count)
        .value(value)
        .build()
}

/// Publishes a metric to CloudWatch
#[instrument(skip(region, namespace), err)]
async fn publish_metric(
    region: &str,
    namespace: &str,
    metrics: Vec<MetricDatum>,
) -> Result<(), Error> {
    let retry_config = RetryConfigBuilder::new()
        .mode(RetryMode::Standard)
        .max_attempts(3)
        .initial_backoff(Duration::from_secs(1))
        .max_backoff(Duration::from_secs(20))
        .reconnect_mode(ReconnectMode::ReconnectOnTransientError)
        .build();
    let config = aws_config::from_env()
        .region(Region::new(region.to_string()))
        .retry_config(retry_config)
        .load()
        .await;

    let client = CloudWatchClient::new(&config);
    client
        .put_metric_data()
        .namespace(namespace)
        .set_metric_data(Some(metrics))
        .send()
        .await
        .context("Failed to put metric data")?;

    Ok(())
}
