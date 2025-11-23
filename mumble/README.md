# Mumble Deployment

## Setup Instructions

### 1. Create the secret file

Copy the template and fill in your actual values:

```bash
cp secret.yaml.template secret.yaml
```

Then edit `secret.yaml` and replace the placeholder values with your actual secrets.

### 2. Apply the manifests

```bash
kubectl apply -f secret.yaml
# Apply other manifests as needed
```

## Security Notes

- `secret.yaml` is gitignored and should never be committed
- Keep your actual secrets secure and use strong passwords
- Consider using a secret management solution like:
  - Sealed Secrets
  - SOPS (Secrets OPerationS)
  - External Secrets Operator
  - HashiCorp Vault
