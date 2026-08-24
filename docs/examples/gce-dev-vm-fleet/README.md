# GCE development VM fleet

This example creates a small fleet of private Google Compute Engine (GCE)
development virtual machines. Each VM uses an Ubuntu 22.04 image, an
8-vCPU, 32-GB `n2-standard-8` instance type, a 128-GB balanced boot disk,
Cloud NAT for egress, and a dedicated service account. You reach the VMs
through Identity-Aware Proxy (IAP), so the instances do not receive external
IP addresses.

The [agent development VM specifications](../../2026-08-24-agent-dev-box-specs.md)
describe the session environment that this example approximates. The
configuration reproduces its main development tools, but it does not reproduce
the Cloud Hypervisor host or its prebaked image.

This example is not what serves production OpenAgents workloads. Use it for
development, experimentation, and capacity planning. Production workloads
follow their own isolation, deployment, and operations contracts.

## What this example creates

- A dedicated VPC and regional subnetwork with Private Google Access.
- A Cloud Router and Cloud NAT for egress without external VM addresses.
- A firewall rule that permits TCP port 22 only from Google's fixed IAP
  TCP-forwarding range, `35.235.240.0/20`.
- A dedicated service account with `roles/logging.logWriter` and
  `roles/monitoring.metricWriter`. The example does not reuse the default
  Compute Engine service account or grant the service account the Editor role.
- A shielded instance template with the development toolchain bootstrap script.
- A zonal managed instance group that maintains `fleet_size` VMs.
- The Compute Engine and IAP APIs.

The example has no backend block. Add a backend that matches your team's state
management requirements before you use it for a real deployment.

## Prerequisites

Before you start, make sure you have:

- Terraform `1.11` or later and before `2.0`.
- A Google Cloud project with billing enabled.
- Permission to enable APIs, create VPC resources, create service accounts,
  grant project IAM roles, and create Compute Engine resources.
- A Google Cloud user or service account configured for the Google provider.
- `gcloud` installed and authenticated when you want to connect through IAP.

The example does not authenticate to Google Cloud during Terraform
configuration validation.

## Deploy the fleet

1. Change to this directory:

   ```console
   cd docs/examples/gce-dev-vm-fleet
   ```

2. Initialize Terraform without a backend:

   ```console
   terraform init -backend=false
   ```

   For a real deployment, run `terraform init` after you add your backend.

3. Review a plan with your project ID:

   ```console
   terraform plan \
     -var='project_id=YOUR_PROJECT_ID'
   ```

4. Apply the configuration:

   ```console
   terraform apply \
     -var='project_id=YOUR_PROJECT_ID'
   ```

Terraform creates ten VMs by default. Set `region`, `zone`, or any other
variable with `-var` or a local `.tfvars` file that you do not commit.

## Scale the fleet

Set `fleet_size` to a value from 1 through 50. The managed instance group
reconciles the target size:

```console
terraform apply \
  -var='project_id=YOUR_PROJECT_ID' \
  -var='fleet_size=20'
```

The `n2-standard-8` default provides 8 vCPUs and 32 GB of memory per VM,
which approximates the recorded development VM. You can select another
Compute Engine instance type when your workload has different CPU or memory
needs.

## Connect through IAP

After the managed instance group creates an instance, list the instance names:

```console
gcloud compute instances list \
  --project=YOUR_PROJECT_ID \
  --filter='name~^openagents-devvm-' \
  --format='value(name)'
```

Connect to one instance through IAP:

```console
gcloud compute ssh INSTANCE_NAME \
  --project=YOUR_PROJECT_ID \
  --zone=us-central1-a \
  --tunnel-through-iap
```

Replace `INSTANCE_NAME` and the zone with values from your deployment.

## Nested virtualization

Set `enable_nested_virtualization = true` only when you want to run a
microVM VMM such as Cloud Hypervisor or Firecracker inside these hosts. The
host type must not be in the E2 family. This example rejects nested
virtualization with an `e2-` instance type.

Nested virtualization also requires an image built with the `vmx` license.
Check the image and the selected Compute Engine region and zone before you
apply this option. Nested virtualization adds overhead and does not turn these
hosts into the same environment as the recorded Cloud Hypervisor guest.

## Cost

On-demand pricing in `us-central1` is roughly $280–$350 per VM per month for
this class of resources, before other project costs such as network egress,
Cloud NAT, and logging. Spot VMs cost materially less, but they can stop and
restart. Confirm current prices and quota before you commit to a fleet size.

## Clean up

When you finish experimenting, destroy the resources:

```console
terraform destroy \
  -var='project_id=YOUR_PROJECT_ID'
```
