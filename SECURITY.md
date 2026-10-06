# Security

## Reporting security issues

If you discover a potential security issue in this project, please do **not**
create a public GitHub issue. Instead, follow the AWS vulnerability reporting
guidance at
[https://aws.amazon.com/security/vulnerability-reporting/](https://aws.amazon.com/security/vulnerability-reporting/).

## Sample scope and threat model

This repository is **sample / tutorial code** that accompanies a blog post. It is
designed to be deployed into **the reader's own AWS account**, run through a
short walkthrough, and then **torn down**. It is intentionally *not* a
production reference architecture.

The security posture reflects that scope. The design goal is to protect the
**reader** who deploys the sample — not to satisfy the long-lived governance,
audit, and operational requirements of a production workload. Concretely, the
sample **keeps** the controls that prevent a reader from exposing or
mis-handling resources, and **omits** governance/operational controls whose
cost or teardown friction outweighs their value in ephemeral demo
infrastructure.

### Controls kept (reader-protecting)

These are deliberately retained and should **not** be removed:

- **Block all public access** on every S3 bucket
  (`BlockPublicAcls`, `BlockPublicPolicy`, `IgnorePublicAcls`, `RestrictPublicBuckets`).
- **Encryption at rest** — S3 buckets use `AES256` (SSE-S3); the SageMaker
  notebook volume uses the default AWS-managed KMS key; ECR repositories use KMS
  encryption with scan-on-push.
- **Scoped IAM**: each role grants only the actions the tutorial uses, scoped to resource ARNs
  wherever the service supports it. The Batch job containers run under a dedicated job role limited to
  the data bucket. The notebook and workflow roles can only manage and submit to this sample's Batch
  compute environment, job queue, and job definition, and can only pass this sample's roles. The only
  grants left on `Resource: "*"` are read and list actions without resource-level permissions
  (Batch `Describe*`/`ListJobs`, Braket `Search*`, `ecr:GetAuthorizationToken`) and the Step Functions
  task callbacks (`states:SendTaskSuccess`/`SendTaskFailure`).
- **Braket limited to SV1**: the notebook and workflow roles can only create hybrid jobs and quantum
  tasks for the SV1 simulator, and the hybrid job's execution role can only create quantum tasks on SV1,
  so the labs can't run on (and bill for) a QPU.
- **HTTPS-only access to the data bucket**: a bucket policy rejects any request not sent
  over TLS (`aws:SecureTransport`).
- **Safe archive extraction**: the Batch job extracts the shadow archive with
  `tarfile`'s `filter="data"`, which rejects paths and links that would leave the target directory.
- **IMDSv2 enforced** on the SageMaker notebook instance.
- **Private subnets** for compute, with VPC endpoints and VPC flow logs.
- **Per-account bucket naming**: the data bucket name includes the account ID and Region
  (`amazon-braket-batch-tutorial-${AWS::AccountId}-${AWS::Region}`), so each deployment gets its own
  bucket name and doesn't clash with other readers' buckets.

### Accepted deviations (intentional, scanner findings suppressed)

The following static-analysis findings are **knowingly accepted** for this
sample. Each is a production governance/operational control that adds cost or
teardown friction without protecting a reader running an ephemeral tutorial.
Inline `# checkov:skip=<ID>:<justification>` comments (the syntax Checkov's
CloudFormation parser recognizes) are present on the relevant resources; this
section additionally covers scanner engines (e.g. CFN_GUARD) that do not honor
Checkov's inline skip syntax at all.

| Finding ID(s) | Control | Resource | Why it is accepted for this sample |
|---|---|---|---|
| `CKV_AWS_187` | Customer-managed KMS key (CMK) for notebook encryption | `BraketNotebookInstance` (`basic-infrastructure.yaml`) | The notebook volume is **already encrypted at rest** with the AWS-managed key. A CMK is a key-*governance* control (rotation, key policy, audit boundaries) relevant to production. It adds ~$1/month plus a mandatory 7–30 day key-deletion window — a surprise cost and teardown footgun for a throwaway demo, protecting nothing a reader cares about. |
| `CKV_AWS_18`, `S3_BUCKET_LOGGING_ENABLED` | S3 server access logging | `DataBucket` (`batch-environment.yaml`) | Access logging is a forensic/audit control ("who touched this bucket months ago"). It requires standing up a **second log bucket** (which itself then wants encryption + public-access-block), adding conceptual noise to a quantum-workflow tutorial. The data is transient, non-sensitive, reproducible tutorial I/O deleted at teardown — nothing whose access history matters. |
| `CKV_AWS_21` | S3 bucket versioning | `DataBucket` (`batch-environment.yaml`) | Versioning protects against accidental loss of **non-reproducible** data. Tutorial outputs (walker energies, `results.json`) are fully reproducible by re-running the batch job. Versioning also **blocks bucket deletion** until every object version is purged, directly adding teardown friction and lingering storage cost for the reader, with no upside. |
| `CKV_AWS_51` | Immutable ECR image tags | `BatchImageRepository`, `LambdaImageRepository` (`batch-environment.yaml`) | The labs rebuild and re-push the images under the same tag while readers iterate on the code; immutable tags would make every re-push fail. The repositories are private to the reader's account, KMS-encrypted, and scanned on push. |
| `CKV_AWS_115` | Reserved concurrency | `LambdaFunction` (`hybrid-workflow.yaml`) | Invoked once per workflow execution by Step Functions. Reserving concurrency would only carve capacity out of the reader's account-wide pool. |
| `CKV_AWS_116` | Dead-letter queue | `LambdaFunction` (`hybrid-workflow.yaml`) | Invoked synchronously by Step Functions; a DLQ only applies to asynchronous invocations. A failure shows up as a failed state in the execution. |
| `CKV_AWS_117` | Lambda inside a VPC | `LambdaFunction` (`hybrid-workflow.yaml`) | The function exposes no network endpoint and only calls Amazon S3 with a role scoped to the data bucket. VPC attachment adds ENIs and a NAT dependency without protecting the reader. |
| `CKV_AWS_173` | KMS key for Lambda environment variables | `LambdaFunction` (`hybrid-workflow.yaml`) | The only variable is the non-secret bucket name. Lambda encrypts environment variables at rest with an AWS managed key by default. |
| `CKV_DOCKER_2` | Dockerfile `HEALTHCHECK` | Both Dockerfiles | AWS Batch runs the container to completion and uses its exit code; Lambda manages its own container lifecycle. Neither uses a Dockerfile `HEALTHCHECK`. |
| `CKV_DOCKER_3` | Non-root container user | Both Dockerfiles | Lambda runs the function as an unprivileged sandbox user regardless of `USER`. The Batch job container runs as root for the sample but only holds `BatchJobRole` credentials (data bucket read/write). |
| bandit `B108` | Hard-coded `/tmp` | `lambda-container-image/collect_total_energies.py` | `/tmp` is the only writable path in Lambda and is private to each execution environment. Suppressed inline with `# nosec B108`. |

### Known limitations

This sample is meant to be deployed into your own AWS account for a short walkthrough and then torn down. The following simplifications are reasonable in that setting, but you should address them before adapting the code for longer-lived or shared environments.

- **Supply chain.** Python requirements and base images are not pinned to exact versions or digests, images are referenced as `:latest`, `pull_afqmc_code.sh` pulls a feature branch of `amazon-braket-examples` without pinning a commit, and the notebook lifecycle configuration downloads and runs the official Amazon Braket notebook setup script without a checksum.
- **Notebook instance defaults.** The notebook uses SageMaker-managed networking with direct internet access and root access enabled (the defaults).
- **`iam:PassRole`** in `NotebookRole` is limited to roles in your own account but has no `iam:PassedToService` condition restricting which service each role can be passed to.
- **Logging.** Step Functions logging and X-Ray tracing are off, and the VPC Flow Logs, Lambda, and Batch log groups have no retention period, so they remain after teardown until you delete them.
- **Device input and scale.** The workflow passes the device ARN from the execution input to the hybrid job without validating it. Any device other than SV1 is rejected when the hybrid job is created, so the execution fails at its first step. The Batch compute environment can scale to 2000 vCPUs by default. Consider AWS Budgets, and [Braket spending limits](https://docs.aws.amazon.com/braket/latest/developerguide/braket-spending-limits.html) if you adapt the sample to run on a QPU.
- **IAM scoping by name prefix.** The Batch permissions match the CloudFormation-generated names of this sample's resources (`BatchComputeEnvironment-*`, `BatchJobQueue-*`, `BatchJobDefinition-*`), so they also match identically named resources created by other stacks in the same account and Region. The Braket job and quantum-task permissions are limited to your account and Region, not to specific jobs.
- **Fixed resource names** (for example `BatchInstanceRole`, `BatchInstanceProfile`, and the stack export names) can collide with existing resources in the account.

## Rationale summary

A public sample should demonstrate the controls that **protect the person who
deploys it** and avoid teaching production governance machinery that readers
would have to pay for and clean up. The deviations above are the governance /
operational controls that fail that test for ephemeral tutorial infrastructure;
everything that keeps a reader safe is retained.
