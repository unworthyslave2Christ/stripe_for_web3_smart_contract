# Stripe for Web3 Smart Contracts

Stripe for Web3 is a decentralized recurring billing protocol powered by ERC-4337 Account Abstraction.

The protocol allows merchants to create subscription plans while subscribers authorize recurring payments without surrendering custody of their assets.

---

## Contracts
contracts/

Web3BillingProtocol.sol

Web3SubscriptionModule.sol

MockERC20.sol


---

## Components

### Web3BillingProtocol

Responsible for

- Merchant registration
- Billing plan creation
- Customer subscriptions
- Billing permissions
- Protocol fees
- Billing history
- Subscription lifecycle

---

### Web3SubscriptionModule

Responsible for

- Account Abstraction execution
- Permission validation
- Authorized recurring payments
- Subscription execution

---

### MockERC20

Development ERC20 token used for

- Testing
- Integration
- Local development
- End-to-end billing validation

---

## Protocol Workflow
