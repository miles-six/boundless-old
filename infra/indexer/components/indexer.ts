import * as fs from 'fs';
import * as aws from '@pulumi/aws';
import * as awsx from '@pulumi/awsx';
import * as docker_build from '@pulumi/docker-build';
import * as pulumi from '@pulumi/pulumi';
import { getServiceNameV1 } from '../../util';
import * as crypto from 'crypto';
const SERVICE_NAME_BASE = 'indexer';

export class IndexerInstance extends pulumi.ComponentResource {
  public readonly dbUrlSecret: aws.secretsmanager.Secret;
  public readonly dbUrlSecretVersion: aws.secretsmanager.SecretVersion;
  public readonly rdsSecurityGroupId: pulumi.Output<string>;

  constructor(
    name: string,
    args: {
      chainId: string;
      ciCacheSecret?: pulumi.Output<string>;
      dockerDir: string;
      dockerTag: string;
      privSubNetIds: pulumi.Output<string[]>;
      pubSubNetIds: pulumi.Output<string[]>;
      githubTokenSecret?: pulumi.Output<string>;
      boundlessAddress: string;
      vpcId: pulumi.Output<string>;
      rdsPassword: pulumi.Output<string>;
      ethRpcUrl: pulumi.Output<string>;
      boundlessAlertsTopicArns?: string[];
      startBlock: string;
      serviceMetricsNamespace: string;
      dockerRemoteBuilder?: string;
    },
    opts?: pulumi.ComponentResourceOptions
  ) {
    super(name, name, opts);

    const {
      ciCacheSecret,
      dockerDir,
      dockerTag,
      privSubNetIds,
      githubTokenSecret,
      boundlessAddress,
      vpcId,
      rdsPassword,
      ethRpcUrl,
      startBlock,
      serviceMetricsNamespace
    } = args;

    const serviceName = name;

    const ecrRepository = new awsx.ecr.Repository(`${serviceName}-repo`, {
      lifecyclePolicy: {
        rules: [
          {
            description: 'Delete untagged images after N days',
            tagStatus: 'untagged',
            maximumAgeLimit: 7,
          },
        ],
      },
      forceDelete: true,
      name: `${serviceName}-repo`,
    });

    const authToken = aws.ecr.getAuthorizationTokenOutput({
      registryId: ecrRepository.repository.registryId,
    });

    // Optionally add in the gh token secret and sccache s3 creds to the build ctx
    let buildSecrets = {};
    if (ciCacheSecret !== undefined) {
      const cacheFileData = ciCacheSecret.apply((filePath: any) => fs.readFileSync(filePath, 'utf8'));
      buildSecrets = {
        ci_cache_creds: cacheFileData,
      };
    }
    if (githubTokenSecret !== undefined) {
      buildSecrets = {
        ...buildSecrets,
        githubTokenSecret
      }
    }

    const image = new docker_build.Image(`${serviceName}-img`, {
      tags: [pulumi.interpolate`${ecrRepository.repository.repositoryUrl}:${dockerTag}`],
      context: {
        location: dockerDir,
      },
      platforms: ['linux/amd64'],
      push: true,
      dockerfile: {
        location: `${dockerDir}/dockerfiles/indexer.dockerfile`,
      },
      builder: args.dockerRemoteBuilder ? {
        name: args.dockerRemoteBuilder,
      } : undefined,
      buildArgs: {
        S3_CACHE_PREFIX: 'private/boundless/rust-cache-docker-Linux-X64/sccache',
      },
      secrets: buildSecrets,
      cacheFrom: [
        {
          registry: {
            ref: pulumi.interpolate`${ecrRepository.repository.repositoryUrl}:cache`,
          },
        },
      ],
      cacheTo: [
        {
          registry: {
            mode: docker_build.CacheMode.Max,
            imageManifest: true,
            ociMediaTypes: true,
            ref: pulumi.interpolate`${ecrRepository.repository.repositoryUrl}:cache`,
          },
        },
      ],
      registries: [
        {
          address: ecrRepository.repository.repositoryUrl,
          password: authToken.apply((authToken) => authToken.password),
          username: authToken.apply((authToken) => authToken.userName),
        },
      ],
    });

    const indexerSecGroup = new aws.ec2.SecurityGroup(`${serviceName}-sg`, {
      name: `${serviceName}-sg`,
      vpcId: vpcId,
      egress: [
        {
          fromPort: 0,
          toPort: 0,
          protocol: '-1',
          cidrBlocks: ['0.0.0.0/0'],
          ipv6CidrBlocks: ['::/0'],
        },
      ],
    });

    const rdsUser = 'indexer';
    const rdsPort = 5432;
    const rdsDbName = 'indexerV1';

    const dbSubnets = new aws.rds.SubnetGroup(`${serviceName}-dbsubnets`, {
      subnetIds: privSubNetIds,
    });

    const rdsSecurityGroup = new aws.ec2.SecurityGroup(`${serviceName}-rds`, {
      name: `${serviceName}-rds`,
      vpcId: vpcId,
      ingress: [
        {
          fromPort: rdsPort,
          toPort: rdsPort,
          protocol: 'tcp',
          securityGroups: [indexerSecGroup.id],
        },
      ],
      egress: [
        {
          fromPort: 0,
          toPort: 0,
          protocol: '-1',
          cidrBlocks: ['0.0.0.0/0'],
        },
      ],
    });

    const auroraCluster = new aws.rds.Cluster(`${serviceName}-aurora-v1`, {
      engine: "aurora-postgresql",
      engineVersion: "17.4",
      clusterIdentifier: `${serviceName}-aurora-v1`,
      databaseName: rdsDbName,
      masterUsername: rdsUser,
      masterPassword: rdsPassword,
      port: rdsPort,
      backupRetentionPeriod: 7,
      skipFinalSnapshot: true,
      dbSubnetGroupName: dbSubnets.name,
      vpcSecurityGroupIds: [rdsSecurityGroup.id],
      storageEncrypted: true,
    }, { /** protect: true **/ }); // TODO: Re-enable protection once deployed and stable.

    const auroraWriter = new aws.rds.ClusterInstance(`${serviceName}-aurora-writer-1`, {
      clusterIdentifier: auroraCluster.id,
      engine: "aurora-postgresql",
      engineVersion: "17.4",
      instanceClass: "db.t4g.medium",
      identifier: `${serviceName}-aurora-writer-v1`,
      publiclyAccessible: false,
      dbSubnetGroupName: dbSubnets.name,
    },
      { /** protect: true **/ } // TODO: Re-enable protection once deployed and stable.
    );

    const dbUrlSecretValue = pulumi.interpolate`postgres://${rdsUser}:${rdsPassword}@${auroraCluster.endpoint}:${rdsPort}/${rdsDbName}?sslmode=require`;
    const dbUrlSecret = new aws.secretsmanager.Secret(`${serviceName}-db-url`);
    const dbUrlSecretVersion = new aws.secretsmanager.SecretVersion(`${serviceName}-db-url-ver`, {
      secretId: dbUrlSecret.id,
      secretString: dbUrlSecretValue,
    });

    const secretHash = pulumi
      .all([dbUrlSecretValue, dbUrlSecretVersion.arn])
      .apply(([_dbUrlSecretValue, _secretVersionArn]: any[]) => {
        const hash = crypto.createHash("sha1");
        hash.update(_dbUrlSecretValue);
        hash.update(_secretVersionArn);
        return hash.digest("hex");
      });

    const dbSecretAccessPolicy = new aws.iam.Policy(`${serviceName}-db-url-policy`, {
      policy: dbUrlSecret.arn.apply((secretArn): aws.iam.PolicyDocument => {
        return {
          Version: '2012-10-17',
          Statement: [
            {
              Effect: 'Allow',
              Action: ['secretsmanager:GetSecretValue', 'ssm:GetParameters'],
              Resource: [secretArn],
            },
          ],
        };
      }),
    });

    const executionRole = new aws.iam.Role(`${serviceName}-ecs-execution-role`, {
      assumeRolePolicy: aws.iam.assumeRolePolicyForPrincipal({
        Service: 'ecs-tasks.amazonaws.com',
      }),
    });

    ecrRepository.repository.arn.apply(_arn => {
      new aws.iam.RolePolicy(`${serviceName}-ecs-execution-pol`, {
        role: executionRole.id,
        policy: {
          Version: '2012-10-17',
          Statement: [
            {
              Effect: 'Allow',
              Action: [
                'ecr:GetAuthorizationToken',
                'ecr:BatchCheckLayerAvailability',
                'ecr:GetDownloadUrlForLayer',
                'ecr:BatchGetImage',
              ],
              Resource: '*',
            },
            {
              Effect: 'Allow',
              Action: [
                'logs:CreateLogStream',
                'logs:PutLogEvents',
              ],
              Resource: '*',
            },
            {
              Effect: 'Allow',
              Action: ['secretsmanager:GetSecretValue', 'ssm:GetParameters'],
              Resource: [dbUrlSecret.arn],
            },
          ],
        },
      });
    })

    const cluster = new aws.ecs.Cluster(`${serviceName}-cluster`, {
      name: `${serviceName}-cluster`,
    });

    const serviceLogGroup = `${serviceName}-service`;

    const taskRole = new aws.iam.Role(`${serviceName}-task`, {
      assumeRolePolicy: aws.iam.assumeRolePolicyForPrincipal({
        Service: 'ecs-tasks.amazonaws.com',
      }),
      managedPolicyArns: [aws.iam.ManagedPolicy.AmazonECSTaskExecutionRolePolicy],
    });

    const taskRolePolicy = new aws.iam.RolePolicyAttachment(`${serviceName}-task-policy`, {
      role: taskRole.id,
      policyArn: dbSecretAccessPolicy.arn,
    });

    const service = new awsx.ecs.FargateService(`${serviceName}-service`, {
      name: `${serviceName}-service`,
      cluster: cluster.arn,
      networkConfiguration: {
        securityGroups: [indexerSecGroup.id],
        assignPublicIp: false,
        subnets: privSubNetIds,
      },
      desiredCount: 1,
      deploymentCircuitBreaker: {
        enable: false,
        rollback: false,
      },
      // forceDelete: true,
      forceNewDeployment: true,
      enableExecuteCommand: true,
      taskDefinitionArgs: {
        logGroup: {
          args: {
            name: serviceLogGroup,
            retentionInDays: 0,
            skipDestroy: true,
          },
        },
        executionRole: { roleArn: executionRole.arn },
        taskRole: { roleArn: taskRole.arn },
        container: {
          name: `${serviceName}`,
          image: image.ref,
          cpu: 1024,
          memory: 512,
          essential: true,
          linuxParameters: {
            initProcessEnabled: true,
          },
          command: [
            '--rpc-url',
            ethRpcUrl,
            '--boundless-market-address',
            boundlessAddress,
            '--start-block',
            startBlock,
            '--log-json'
          ],
          secrets: [
            {
              name: 'DATABASE_URL',
              valueFrom: dbUrlSecret.arn,
            },
          ],
          environment: [
            {
              name: 'RUST_LOG',
              value: 'boundless_indexer=debug,info',
            },
            {
              name: 'NO_COLOR',
              value: '1',
            },
            {
              name: 'RUST_BACKTRACE',
              value: '1',
            },
            {
              name: 'DB_POOL_SIZE',
              value: '5',
            },
            {
              name: 'SECRET_HASH',
              value: secretHash,
            }
          ]
        },
      },
    }, { dependsOn: [taskRole, taskRolePolicy] });

    const alarmActions = args.boundlessAlertsTopicArns ?? [];

    new aws.cloudwatch.LogMetricFilter(`${serviceName}-log-err-filter`, {
      name: `${serviceName}-log-err-filter`,
      logGroupName: serviceLogGroup,
      metricTransformation: {
        namespace: serviceMetricsNamespace,
        name: `${serviceName}-log-err`,
        value: '1',
        defaultValue: '0',
      },
      // Whitespace prevents us from alerting on SQL injection probes.
      pattern: `"ERROR "`,
    }, { dependsOn: [service] });

    // Two errors within an hour triggers alarm.
    new aws.cloudwatch.MetricAlarm(`${serviceName}-error-alarm`, {
      name: `${serviceName}-log-err`,
      metricQueries: [
        {
          id: 'm1',
          metric: {
            namespace: serviceMetricsNamespace,
            metricName: `${serviceName}-log-err`,
            period: 60,
            stat: 'Sum',
          },
          returnData: true,
        },
      ],
      threshold: 1,
      comparisonOperator: 'GreaterThanOrEqualToThreshold',
      // Two errors within an hour triggers alarm.
      evaluationPeriods: 60,
      datapointsToAlarm: 2,
      treatMissingData: 'notBreaching',
      alarmDescription: 'Indexer log ERROR level',
      actionsEnabled: true,
      alarmActions,
    });

    new aws.cloudwatch.LogMetricFilter(`${serviceName}-fatal-filter`, {
      name: `${serviceName}-log-fatal-filter`,
      logGroupName: serviceLogGroup,
      metricTransformation: {
        namespace: serviceMetricsNamespace,
        name: `${serviceName}-log-fatal`,
        value: '1',
        defaultValue: '0',
      },
      pattern: 'FATAL',
    }, { dependsOn: [service] });

    new aws.cloudwatch.MetricAlarm(`${serviceName}-fatal-alarm`, {
      name: `${serviceName}-log-fatal`,
      metricQueries: [
        {
          id: 'm1',
          metric: {
            namespace: serviceMetricsNamespace,
            metricName: `${serviceName}-log-fatal`,
            period: 60,
            stat: 'Sum',
          },
          returnData: true,
        },
      ],
      threshold: 1,
      comparisonOperator: 'GreaterThanOrEqualToThreshold',
      evaluationPeriods: 1,
      datapointsToAlarm: 1,
      treatMissingData: 'notBreaching',
      alarmDescription: `Indexer ${name} FATAL (task exited)`,
      actionsEnabled: true,
      alarmActions,
    });

    this.dbUrlSecret = dbUrlSecret;
    this.dbUrlSecretVersion = dbUrlSecretVersion;
    this.rdsSecurityGroupId = rdsSecurityGroup.id;


    this.registerOutputs({
      dbUrlSecret: this.dbUrlSecret,
      dbUrlSecretVersion: this.dbUrlSecretVersion,
      rdsSecurityGroupId: this.rdsSecurityGroupId
    });
  }
}
