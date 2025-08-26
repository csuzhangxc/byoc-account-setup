# TiDB Cloud Byoc Bastion Deployment

This Terraform project provisions an AWS EC2 instance to serve as a bastion host. This bastion allows secure interaction with your TiDB Cloud Bring Your Own Cloud (BYOC) EKS cluster.

## Prerequisites

Before you begin, ensure you have the following:

1. **Terraform Installed**  
   * Ensure Terraform is installed locally. 

2. **AWS CLI Configured**
   * Your AWS CLI must be configured with appropriate credentials and permissions for your AWS account.
   * Necessary permissions include actions for EC2, IAM, and EKS.

3. **Existing TiDB Cloud BYOC Cluster**  
   * You need an active TiDB Cloud BYOC cluster.
   * You'll need its EKS cluster name.

4. **Information from TiDB Cloud**
   * Your TiDB Cloud Tenant ID.
   * Tailscale authentication keys for the bastion(s), provided by TiDB Cloud.

## Deployment

Follow these steps to deploy the bastion(s):

1. **Obtain Credentials from TiDB Cloud:**
   
   Contact TiDB Cloud support to get your:
      * `tidbcloud_tenant_id`
      * Tailscale authentication keys (`auth_key`) for each bastion type you intend to deploy (e.g., for `tidb` and/or `o11y`).

2. **Identify EKS Cluster Name(s):**

   Determine the EKS cluster name(s) associated with your BYOC deployment that the bastion(s) will connect to.

3. **Initialize Terraform:**

   The default backend for this project is S3. Update the `terraform.tf` file with your S3 bucket information as shown below:

   ```hcl
   terraform {
     required_providers {
       aws = {
         source  = "hashicorp/aws"
         version = "~> 5.0"
       }
     }

     backend "s3" {
       bucket = "YOUR_S3_BUCKET"
       key    = "TF_STATE_FILE_PATH"
       region = "us-west-2"
     }
   }
   ```

   After updating the backend configuration, initialize the Terraform working directory:

   ```bash
   terraform init
   ```

   If you prefer to use a different [Terraform backend](https://developer.hashicorp.com/terraform/language/backend), modify the `terraform.tf` file accordingly and initialize with your chosen backend configuration.

4. **Prepare `terraform.tfvars` File:**

   Copy the example variables file and customize it:

   ```bash
   cp examples/terraform.tfvars.example ./terraform.tfvars
   vim ./terraform.tfvars
   ```

   Update the following required fields:
   * `aws_region`: (String) The AWS region where your TiDB Cloud BYOC cluster is deployed (e.g., "us-west-2").
   * `tidbcloud_tenant_id`: (String) Your TiDB Cloud tenant ID (obtained in Step 1).
   * `bastions`: (Map) A map defining bastion configurations. You can configure bastions for `tidb` (TiDB cluster access) and/or `o11y` (observability services access).
     * `<bastion_type>.eks_cluster_name`: (String) The EKS cluster name for this bastion type (e.g., `tidb.eks_cluster_name` or `o11y.eks_cluster_name`).
     * `<bastion_type>.auth_key`: (String) The Tailscale authentication key provided by TiDB Cloud for this bastion type (obtained in Step 1).

   Example bastions configuration in `terraform.tfvars`:

   ```
   aws_region = "us-west-2"

   tidbcloud_tenant_id = "your_tidbcloud_tenant_id"

   bastions = {
      tidb = {
         eks_cluster_name    = "your-tidb-eks-cluster"
         auth_key  = "tskey-key-xxxxxxxx"
      },
      o11y = {
         eks_cluster_name    = "your-o11y-eks-cluster" # Often the same as TiDB EKS cluster
         auth_key  = "tskey-key-xxxxxxxx"
      }
   }
   ```

   For a comprehensive list of all configurable variables and their descriptions, please refer to the [variables.tf](./variables.tf).


5. Deploy the Bastion(s):
   
   Apply the Terraform configuration:

   ```bash
   terraform apply
   ```

   Terraform will show you a plan of the resources to be created. Review it carefully and type `yes` to confirm and proceed with the deployment.

6. Verify and Share Output:

   Once the deployment is complete, retrieve the output values:

   ```output
   terraform output
   ```

   The output will look similar to this:

   ```terraform
   bastion_attributes = tomap({
      "bastion_name" = {
         "o11y" = "<bastion_o11y_name>"
         "tidb" = "<bastion_tidb_name>"
      }
      "instance_id" = {
         "o11y" = "<instance_o11y_id>"
         "tidb" = "<instance_tidb_id>"
      }
   })
   ```

   Provide this output to TiDB Cloud support. This allows them to verify connectivity from their end and complete any necessary network configurations.

## Cleanup

To remove the bastion host(s) and associated resources created by this Terraform configuration, run:

```bash
terraform destroy
```

## Auth Key Management

* **Expiration**: The authentication keys provided by TiDB Cloud are single-use, ephemeral and typically expire after 3 days.

* **Existing Deployments**: Key expiry does not affect already deployed and running bastion hosts that were successfully configured with a valid key.

* **Re-deployments / New Deployments**: If you need to run `terraform apply` (e.g., to create a new bastion or re-create an existing one) after keys have expired, you must request new authentication keys from TiDB Cloud. Update the `auth_key` values in your `terraform.tfvars` file before applying.

## Manage Bastion

You can manage the Bastion host via AWS Systems Manager (SSM) after it has been deployed.

```bash
aws ssm start-session --region <region> --target <instance_id> --reason <reason>
```

To temporarily revoke TiDB Cloud's access to this Bastion host, run the following command on the Bastion:

```bash
tailscale down
```

To restore TiDB Cloud's access to the Bastion, run the following command on the Bastion:

```bash
tailscale up
```


## Audit Log Collection

For enhanced security and compliance, each bastion host is configured by default to capture a detailed audit trail of all executed commands via [auditd service](https://docs.redhat.com/en/documentation/red_hat_enterprise_linux/6/html/security_guide/chap-system_auditing).

Audit logs are located at `/var/log/audit/audit.log` and are automatically forwarded to a dedicated AWS CloudWatch Log Group: `/aws/eks/${eks_cluster_name}/byoc-bastion/audit`. To ensure a sufficient history for analysis, logs are retained in CloudWatch for 90 days by default.

You can set the variable `cloudwatch_audit_enable: false` to disable log forwarding.