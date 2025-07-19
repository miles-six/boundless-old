// Copyright 2025 RISC Zero, Inc.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

//! Provider implementations for uploading image and input files such that they are publicly
//! accessible to provers.

use std::{fmt::Debug, ops::Deref, path::PathBuf, result::Result::Ok, sync::Arc};

use async_trait::async_trait;
use clap::{builder::ArgPredicate, Args, ValueEnum};
use derive_builder::Builder;
use reqwest::Url;

mod fetch;
mod file;
mod mock;
mod pinata;
mod s3;

pub use fetch::fetch_url;
pub use file::{TempFileStorageProvider, TempFileStorageProviderError};
pub use mock::{MockStorageError, MockStorageProvider};
pub use pinata::{PinataStorageProvider, PinataStorageProviderError};
pub use s3::{S3StorageProvider, S3StorageProviderError};

#[async_trait]
/// A trait for uploading risc0-zkvm programs and input files to a storage provider.
pub trait StorageProvider {
    /// Error type for the storage provider.
    type Error: Debug;

    /// Upload a risc0-zkvm program binary.
    ///
    /// Returns the URL which can be used to publicly access the uploaded program. This URL can be
    /// included in a request sent to Boundless.
    async fn upload_program(&self, program: &[u8]) -> Result<Url, Self::Error>;

    /// Upload the input for use in a proof request.
    ///
    /// Returns the URL which can be used to publicly access the uploaded input. This URL can be
    /// included in a request sent to Boundless.
    async fn upload_input(&self, input: &[u8]) -> Result<Url, Self::Error>;
}

#[async_trait]
impl<S: StorageProvider + Sync + ?Sized> StorageProvider for Box<S> {
    type Error = S::Error;

    async fn upload_program(&self, program: &[u8]) -> Result<Url, Self::Error> {
        self.deref().upload_program(program).await
    }

    async fn upload_input(&self, input: &[u8]) -> Result<Url, Self::Error> {
        self.deref().upload_input(input).await
    }
}

#[async_trait]
impl<S: StorageProvider + Sync + Send + ?Sized> StorageProvider for Arc<S> {
    type Error = S::Error;

    async fn upload_program(&self, program: &[u8]) -> Result<Url, Self::Error> {
        self.deref().upload_program(program).await
    }

    async fn upload_input(&self, input: &[u8]) -> Result<Url, Self::Error> {
        self.deref().upload_input(input).await
    }
}

#[derive(Clone, Debug)]
#[non_exhaustive]
/// A storage provider that can be used to upload images and inputs to a public URL.
pub enum StandardStorageProvider {
    /// S3 storage provider.
    S3(S3StorageProvider),
    /// Pinata storage provider.
    Pinata(PinataStorageProvider),
    /// Temporary file storage provider, used for local testing.
    File(TempFileStorageProvider),
    /// Mock storage provider, used for local testing.
    #[cfg(feature = "test-utils")]
    Mock(Arc<MockStorageProvider>),
}

#[derive(thiserror::Error, Debug)]
#[non_exhaustive]
/// Error type for the builtin storage providers.
pub enum StandardStorageProviderError {
    /// Error type for the S3 storage provider.
    #[error("S3 storage provider error")]
    S3(#[from] S3StorageProviderError),
    /// Error type for the Pinata storage provider.
    #[error("Pinata storage provider error")]
    Pinata(#[from] PinataStorageProviderError),
    /// Error type for the temporary file storage provider.
    #[error("temp file storage provider error")]
    File(#[from] TempFileStorageProviderError),
    /// Error type for the mock storage provider.
    #[cfg(feature = "test-utils")]
    #[error("mock storage provider error")]
    Mock(#[from] MockStorageError),
    /// Error type for an invalid storage provider.
    #[error("Invalid storage provider: {0}")]
    InvalidProvider(String),
    /// Error type for when no storage provider is configured.
    #[error("no storage provider is configured")]
    NoProvider,
}

#[derive(Default, Clone, Debug, ValueEnum)]
#[non_exhaustive]
/// The type of storage provider to use.
pub enum StorageProviderType {
    /// No storage provider.
    #[default]
    None,
    /// S3 storage provider.
    S3,
    /// Pinata storage provider.
    Pinata,
    /// Temporary file storage provider.
    File,
    /// Mock storage provider.
    #[cfg(feature = "test-utils")]
    Mock,
}

/// Configuration for the storage provider.
#[non_exhaustive]
#[derive(Clone, Default, Debug, Args, Builder)]
pub struct StorageProviderConfig {
    /// Storage provider to use [possible values: s3, pinata, file]
    ///
    /// - For 's3', the following options are required:
    ///   --s3-access-key, --s3-secret-key, --s3-bucket, --s3-url, --aws-region
    /// - For 'pinata', the following option is required:
    ///   --pinata-jwt (optionally, you can specify --pinata-api-url, --ipfs-gateway-url)
    /// - For 'file', no additional options are required (optionally, you can specify --file-path)    
    #[arg(long, env, value_enum, default_value = "none", default_value_ifs = [
        ("s3_access_key", ArgPredicate::IsPresent, "s3"),
        ("pinata_jwt", ArgPredicate::IsPresent, "pinata"),
        ("file_path", ArgPredicate::IsPresent, "file")
    ])]
    #[builder(default)]
    pub storage_provider: StorageProviderType,

    // **S3 Storage Provider Options**
    /// S3 access key
    #[arg(long, env, required_if_eq("storage_provider", "s3"))]
    #[builder(setter(strip_option, into), default)]
    pub s3_access_key: Option<String>,
    /// S3 secret key
    #[arg(long, env, required_if_eq("storage_provider", "s3"))]
    #[builder(setter(strip_option, into), default)]
    pub s3_secret_key: Option<String>,
    /// S3 bucket
    #[arg(long, env, required_if_eq("storage_provider", "s3"))]
    #[builder(setter(strip_option, into), default)]
    pub s3_bucket: Option<String>,
    /// S3 URL
    #[arg(long, env, required_if_eq("storage_provider", "s3"))]
    #[builder(setter(strip_option, into), default)]
    pub s3_url: Option<String>,
    /// S3 region
    #[arg(long, env, required_if_eq("storage_provider", "s3"))]
    #[builder(setter(strip_option, into), default)]
    pub aws_region: Option<String>,
    /// Use presigned URLs for S3
    #[arg(long, env, requires("s3_access_key"), default_value = "true")]
    #[builder(setter(strip_option), default)]
    pub s3_use_presigned: Option<bool>,

    // **Pinata Storage Provider Options**
    /// Pinata JWT
    #[arg(long, env, required_if_eq("storage_provider", "pinata"))]
    #[builder(setter(strip_option, into), default)]
    pub pinata_jwt: Option<String>,
    /// Pinata API URL
    #[arg(long, env, requires("pinata_jwt"))]
    #[builder(setter(strip_option), default)]
    pub pinata_api_url: Option<Url>,
    /// Pinata gateway URL
    #[arg(long, env, requires("pinata_jwt"))]
    #[builder(setter(strip_option), default)]
    pub ipfs_gateway_url: Option<Url>,

    // **File Storage Provider Options**
    /// Path for file storage provider
    #[arg(long)]
    #[builder(setter(strip_option, into), default)]
    pub file_path: Option<PathBuf>,
}

impl StorageProviderConfig {
    /// Create a new [StorageProviderConfigBuilder] to construct a config.
    pub fn builder() -> StorageProviderConfigBuilder {
        Default::default()
    }

    /// Create a new configuration for a [StorageProviderType::File].
    pub fn dev_mode() -> Self {
        Self {
            storage_provider: StorageProviderType::File,
            s3_access_key: None,
            s3_secret_key: None,
            s3_bucket: None,
            s3_url: None,
            s3_use_presigned: None,
            aws_region: None,
            pinata_jwt: None,
            pinata_api_url: None,
            ipfs_gateway_url: None,
            file_path: None,
        }
    }
}

#[async_trait]
impl StorageProvider for StandardStorageProvider {
    type Error = StandardStorageProviderError;

    async fn upload_program(&self, program: &[u8]) -> Result<Url, Self::Error> {
        Ok(match self {
            Self::S3(provider) => provider.upload_program(program).await?,
            Self::Pinata(provider) => provider.upload_program(program).await?,
            Self::File(provider) => provider.upload_program(program).await?,
            #[cfg(feature = "test-utils")]
            Self::Mock(provider) => provider.upload_program(program).await?,
        })
    }

    async fn upload_input(&self, input: &[u8]) -> Result<Url, Self::Error> {
        Ok(match self {
            Self::S3(provider) => provider.upload_input(input).await?,
            Self::Pinata(provider) => provider.upload_input(input).await?,
            Self::File(provider) => provider.upload_input(input).await?,
            #[cfg(feature = "test-utils")]
            Self::Mock(provider) => provider.upload_input(input).await?,
        })
    }
}

/// Creates a storage provider based on the environment variables.
///
/// If the environment variable `RISC0_DEV_MODE` is set, a temporary file storage provider is used.
/// Otherwise, the following environment variables are checked in order:
/// - `PINATA_JWT`, `PINATA_API_URL`, `IPFS_GATEWAY_URL`: Pinata storage provider;
/// - `S3_ACCESS`, `S3_SECRET`, `S3_BUCKET`, `S3_URL`, `AWS_REGION`: S3 storage provider.
pub fn storage_provider_from_env() -> Result<StandardStorageProvider, StandardStorageProviderError>
{
    if risc0_zkvm::is_dev_mode() {
        return Ok(StandardStorageProvider::File(TempFileStorageProvider::new()?));
    }

    if let Ok(provider) = PinataStorageProvider::from_env() {
        return Ok(StandardStorageProvider::Pinata(provider));
    }

    if let Ok(provider) = S3StorageProvider::from_env() {
        return Ok(StandardStorageProvider::S3(provider));
    }

    Err(StandardStorageProviderError::NoProvider)
}

/// Creates a storage provider based on the given configuration.
pub fn storage_provider_from_config(
    config: &StorageProviderConfig,
) -> Result<StandardStorageProvider, StandardStorageProviderError> {
    match config.storage_provider {
        StorageProviderType::S3 => {
            let provider = S3StorageProvider::from_config(config)?;
            Ok(StandardStorageProvider::S3(provider))
        }
        StorageProviderType::Pinata => {
            let provider = PinataStorageProvider::from_config(config)?;
            Ok(StandardStorageProvider::Pinata(provider))
        }
        StorageProviderType::File => {
            let provider = TempFileStorageProvider::from_config(config)?;
            Ok(StandardStorageProvider::File(provider))
        }
        #[cfg(feature = "test-utils")]
        StorageProviderType::Mock => {
            let provider = MockStorageProvider::start();
            Ok(StandardStorageProvider::Mock(Arc::new(provider)))
        }
        StorageProviderType::None => Err(StandardStorageProviderError::NoProvider),
    }
}

impl StandardStorageProvider {
    /// Creates a storage provider based on the environment variables.
    ///
    /// See [storage_provider_from_env()].
    pub async fn from_env() -> Result<Self, <Self as StorageProvider>::Error> {
        storage_provider_from_env()
    }

    /// Creates a storage provider based on the given configuration.
    pub fn from_config(
        config: &StorageProviderConfig,
    ) -> Result<Self, <Self as StorageProvider>::Error> {
        storage_provider_from_config(config)
    }
}
