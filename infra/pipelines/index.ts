import { PulumiStateBucket } from "./components/pulumiState";
import { PulumiSecrets } from "./components/pulumiSecrets";
import { SamplePipeline } from "./pipelines/sample";
import { ProverPipeline } from "./pipelines/prover";
import { SlasherPipeline } from "./pipelines/slasher";
import { Notifications } from "./components/notifications";
import { OrderGeneratorPipeline } from "./pipelines/order-generator";
import { OrderStreamPipeline } from "./pipelines/order-stream";
import { IndexerPipeline } from "./pipelines/indexer";
import { DistributorPipeline } from "./pipelines/distributor";
import { CodePipelineSharedResources } from "./components/codePipelineResources";
import * as aws from "@pulumi/aws";
import {
  BOUNDLESS_DEV_ADMIN_ROLE_ARN,
  BOUNDLESS_OPS_ACCOUNT_ID,
  BOUNDLESS_STAGING_DEPLOYMENT_ROLE_ARN,
  BOUNDLESS_PROD_DEPLOYMENT_ROLE_ARN,
  BOUNDLESS_STAGING_ADMIN_ROLE_ARN,
  BOUNDLESS_PROD_ADMIN_ROLE_ARN,
  BOUNDLESS_STAGING_ACCOUNT_ID,
  BOUNDLESS_PROD_ACCOUNT_ID
} from "./accountConstants";
import * as pulumi from '@pulumi/pulumi';

// Defines the S3 bucket used for storing the Pulumi state backend for staging and prod accounts.
const pulumiStateBucket = new PulumiStateBucket("pulumiStateBucket", {
  accountId: BOUNDLESS_OPS_ACCOUNT_ID,
  readOnlyStateBucketArns: [
    BOUNDLESS_DEV_ADMIN_ROLE_ARN,
  ],
  readWriteStateBucketArns: [
    BOUNDLESS_STAGING_ADMIN_ROLE_ARN,
    BOUNDLESS_PROD_ADMIN_ROLE_ARN,
    BOUNDLESS_STAGING_DEPLOYMENT_ROLE_ARN,
    BOUNDLESS_PROD_DEPLOYMENT_ROLE_ARN,
  ],
});

// Defines the KMS key used to encrypt and decrypt secrets. 
// Currently, developers logged in as Admin in the Boundless Dev account can encrypt and decrypt secrets.
// TODO: Only deployment roles should be allowed to decrypt secrets.
// Staging and prod deployement roles are the only accounts allowed to decrypt secrets.
const pulumiSecrets = new PulumiSecrets("pulumiSecrets", {
  accountId: BOUNDLESS_OPS_ACCOUNT_ID,
  encryptKmsKeyArns: [
    BOUNDLESS_DEV_ADMIN_ROLE_ARN
  ],
  decryptKmsKeyArns: [
    BOUNDLESS_DEV_ADMIN_ROLE_ARN,
    BOUNDLESS_STAGING_DEPLOYMENT_ROLE_ARN,
    BOUNDLESS_PROD_DEPLOYMENT_ROLE_ARN,
  ],
});

// Defines the connection to the "AWS Connector for Github" app on Github.
// Note that the initial setup for the app requires a manual step that must be done in the console. If this
// resource is ever deleted, this step will need to be repeated. See:
// https://docs.aws.amazon.com/codepipeline/latest/userguide/connections-github.html
const githubConnection = new aws.codestarconnections.Connection("boundlessGithubConnection", {
  name: "boundlessGithubConnection",
  providerType: "GitHub",
});

// Resouces that are shared between all deployment pipelines like IAM roles, S3 artifact buckets, etc.
const codePipelineSharedResources = new CodePipelineSharedResources("codePipelineShared", {
  accountId: BOUNDLESS_OPS_ACCOUNT_ID,
  serviceAccountDeploymentRoleArns: [
    BOUNDLESS_STAGING_DEPLOYMENT_ROLE_ARN,
    BOUNDLESS_PROD_DEPLOYMENT_ROLE_ARN,
  ],
});

const config = new pulumi.Config();
const boundlessAlertsSlackId = config.requireSecret("BOUNDLESS_ALERTS_SLACK_ID");
const boundlessAlertsStagingSlackId = config.requireSecret("BOUNDLESS_ALERTS_STAGING_SLACK_ID");
const workspaceSlackId = config.requireSecret("WORKSPACE_SLACK_ID");
const pagerdutyIntegrationUrl = config.requireSecret("PAGERDUTY_INTEGRATION_URL");
const ssoBaseUrl = config.require("SSO_BASE_URL");
const runbookUrl = config.require("RUNBOOK_URL");

const notifications = new Notifications("notifications", {
  opsAccountId: BOUNDLESS_OPS_ACCOUNT_ID,
  serviceAccountIds: [
    BOUNDLESS_OPS_ACCOUNT_ID,
    BOUNDLESS_STAGING_ACCOUNT_ID,
    BOUNDLESS_PROD_ACCOUNT_ID,
  ],
  prodSlackChannelId: boundlessAlertsSlackId,
  stagingSlackChannelId: boundlessAlertsStagingSlackId,
  slackTeamId: workspaceSlackId,
  pagerdutyIntegrationUrl,
  ssoBaseUrl,
  runbookUrl,
});

// The Docker and GH tokens are used to avoid rate limiting issues when building in the pipelines.
const githubToken = config.requireSecret("GITHUB_TOKEN");
const dockerUsername = config.require("DOCKER_USER");
const dockerToken = config.requireSecret("DOCKER_PAT");

// Create the deployment pipeline for the "sample" app.
const samplePipeline = new SamplePipeline("samplePipeline", {
  connection: githubConnection,
  artifactBucket: codePipelineSharedResources.artifactBucket,
  role: codePipelineSharedResources.role,
});

const proverPipeline = new ProverPipeline("proverPipeline", {
  connection: githubConnection,
  artifactBucket: codePipelineSharedResources.artifactBucket,
  role: codePipelineSharedResources.role,
  githubToken,
  dockerUsername,
  dockerToken,
  slackAlertsTopicArn: notifications.slackSNSTopic.arn,
})

const orderGeneratorPipeline = new OrderGeneratorPipeline("orderGeneratorPipeline", {
  connection: githubConnection,
  artifactBucket: codePipelineSharedResources.artifactBucket,
  role: codePipelineSharedResources.role,
  githubToken,
  dockerUsername,
  dockerToken,
  slackAlertsTopicArn: notifications.slackSNSTopic.arn,
})

const slasherPipeline = new SlasherPipeline("slasherPipeline", {
  connection: githubConnection,
  artifactBucket: codePipelineSharedResources.artifactBucket,
  role: codePipelineSharedResources.role,
  githubToken,
  dockerUsername,
  dockerToken,
  slackAlertsTopicArn: notifications.slackSNSTopic.arn,
})

const orderStreamPipeline = new OrderStreamPipeline("orderStreamPipeline", {
  connection: githubConnection,
  artifactBucket: codePipelineSharedResources.artifactBucket,
  role: codePipelineSharedResources.role,
  githubToken,
  dockerUsername,
  dockerToken,
  slackAlertsTopicArn: notifications.slackSNSTopic.arn,
})

const indexerPipeline = new IndexerPipeline("indexerPipeline", {
  connection: githubConnection,
  artifactBucket: codePipelineSharedResources.artifactBucket,
  role: codePipelineSharedResources.role,
  githubToken,
  dockerUsername,
  dockerToken,
  slackAlertsTopicArn: notifications.slackSNSTopic.arn,
})

const distributorPipeline = new DistributorPipeline("distributorPipeline", {
  connection: githubConnection,
  artifactBucket: codePipelineSharedResources.artifactBucket,
  role: codePipelineSharedResources.role,
  githubToken,
  dockerUsername,
  dockerToken,
  slackAlertsTopicArn: notifications.slackSNSTopic.arn,
})

export const bucketName = pulumiStateBucket.bucket.id;
export const kmsKeyArn = pulumiSecrets.kmsKey.arn;
export const boundlessAlertsTopicArn = notifications.slackSNSTopic.arn;
export const boundlessPagerdutyTopicArn = notifications.pagerdutySNSTopic.arn;