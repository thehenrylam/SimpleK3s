# idp_cognito — Standalone AWS Cognito IdP (OIDC)

This Terraform module provisions a lightweight, managed Identity Provider (IdP) on AWS using **Amazon Cognito User Pools**.

It’s designed to be **easy to spin up / tear down** and integrate with apps that support **OIDC** (OAuth2), such as:
- Argo CD
- Grafana
- Jenkins (OIDC plugins)
- oauth2-proxy (for Prometheus, etc.)

## What it creates

- Cognito **User Pool**
- Cognito **App Client** (OIDC) with a generated client secret
- Cognito **Hosted UI domain** (AWS-managed domain prefix)
- (Optional) a **test user**
- (Optional) a **group** and group membership for the test user

## Requirements

- Terraform >= 1.11.0
- AWS provider configured with credentials + region

## Usage

```hcl
provider "aws" {
    region = "us-east-1"
}

module "idp" {
    source = "../../modules/idp_cognito"

    nickname        = "proof-of-concept-idp"

    callback_urls = [
        # Argo CD UI callback
        "https://argocd.example.com/auth/callback",

        # Optional (Argo CD CLI SSO login uses localhost callback)
        "http://localhost:8085/auth/callback",
    ]

    logout_urls = [
        "https://argocd.example.com/",
    ]

    group_names = ["platform-admins"]

    users = [
        {
            username = "test@example.com"
        },
        {
            username = "admin@example.com"
            group    = "platform-admins"
        },
    ]

    tags = {
        Project = "IdP_Standalone"
    }
}
