# CloudPi

CloudPi provides cloud cost governance and build tooling to help deploy scalable cloud platforms. The project includes Docker and cloud templates, as well as documentation for deployment and launching cloudpi on AWS EC2 with container image.

**Note:** This repository contains the paid, proprietary version of CloudPi. Use is restricted to customers or those with explicit permission from PurpleData Inc.

## Features

- **Infrastructure as Code:** Includes YAML cloud templates for automated provisioning.
- **Docker Compose:** Standardized container orchestration setup with `docker-compose.yml`.
- **Deployment Documentation:** Guides for platform deployment and Docker Compose usage on cloud Virtual Machines (Aws/Azure/Gcp)
- **Environment Configuration:** Example `.env` for environment variable management.

## Repository Structure

- `docker-compose.yml`: Container orchestration file.
- `cloud-template.yaml`: Cloud infrastructure template.
- `.env`: Example environment setup.
- `CloudPi Platform Deployment Guide.docx`: End-to-end deployment guide.
- `Run Docker Compose on EC2 instance.docx`: Step-by-step guide for deploying on AWS EC2.

## Getting Started

1. Review documentation files for instructions.
2. Copy `.env` and configure settings for your environment.
3. Use `docker-compose.yml` to build and deploy containers.
4. Utilize `cloud-template.yaml` or CloudFormation documentation for cloud setup.

## Requirements

- Docker
- AWS Account (for cloud deployments)

## License

This software is proprietary and paid. See [LICENSE](./LICENSE) for details on usage and distribution.

## Contributing

Pull requests and issues are welcome from licensed users. Please ensure all contributions follow the project's guidelines.

## Contact

Maintained by PurpleData Inc.
