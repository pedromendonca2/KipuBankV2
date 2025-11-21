# KipuBankV2

The contract now supports access control with admin roles (restricting sensitive actions), integrates real-time ETH/USD prices from Chainlink for fiat-denominated limits, allows deposits and withdrawals of both ETH and arbitrary ERC-20 tokens via a unified multi-asset vault, and internally normalizes all accounting to USDC's 6 decimals for consistency. These improvements make vault operations safer, more flexible, and adaptable to multiple asset types.

Instructions for Deployment and Interaction

- Deploy the contract specifying the withdrawal limit and bank cap (in USDC decimals), and providing the Chainlink ETH/USD price feed address for your network.

- Assign appropriate roles via the AccessControl system (grantRole for other admins).

- Users can deposit either ETH (by sending funds and using address(0)) or ERC-20 tokens (using the deposit function and the token's address).

- Withdrawals can be made for any token, respecting USD-denominated per-transaction limits.

- Admins can use adminWithdraw for emergency recovery.

- Use the statistics functions to view a user's asset history and balances per token.

Design Decisions and Trade-offs

- Access Control: Chosen for clear separation of responsibilities and upgradability; could be more granular, but default admin/role-model is sufficient.

- Chainlink Price Feeds: Ensures up-to-date fiat denominated limits, but incurs extra gas cost and dependency on aggregator liveness.

- Decimals Normalization: USDC (6 decimals) chosen for industry standard, but requires conversion for other assets, introducing potential rounding errors for tokens with fewer decimals.

- Multi-token Architecture: Mapping structure enables future expansion to more assets, but increases complexity and requires careful audit of all cross-token logic.

- ERC-20 Default Pricing: Defaults to 1 USD for stablecoins; for non-stables, more price feeds or oracle integrations may be necessary for secure valuation.

- Checks-Effects-Interactions: Rigorously applied for safety; can introduce some code repetition for clarity.
