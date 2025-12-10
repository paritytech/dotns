# dotNS - Deployment instructions

## Requirements

1. bun
2. foundry
3. cast

## Instructions

1. Install the dependencies and create a cast wallet

```bash
bun install
cast wallet import revive --interactive`
```

You may use the following private key: `e1d6ffdeeeee2fa692dcb276491d2ee4ffc3e97b899695d712a573c8d043202e`
And the password set to `123456`

2. Run the deployment script

```bash
chmod +x deploy.sh
./deploy.sh
```

## Development

> Notice: A new field was added to the registration contract `IndividualityType`
> The reason is to mock PoP functionalities that will be available in the future.
> That should be removed as soon as proof of personhood is available to use in this application.

For running tests you might run:

```bash
bun run test
```
