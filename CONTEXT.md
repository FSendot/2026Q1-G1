# Fraud Detector

This context describes the fraud detection lab domain, especially the distinction between transaction subjects and dashboard access control.

## Language

**Transaction User**:
The internal tenant user whose financial activity is scored and profiled for fraud detection.
_Avoid_: Dashboard user, Cognito user

**Dashboard User**:
A human who authenticates through the dashboard user pool to access the dashboard and API.
_Avoid_: Transaction user, profile user

**Dashboard Access Grant**:
Permission given by an existing dashboard insider that allows a dashboard user to view dashboard and API data.
_Avoid_: Cognito account, transaction profile

**Dashboard Invite**:
An invitation for a verified email address to become a dashboard user after authentication.
_Avoid_: Pre-created password account

**Display Name**:
The human-readable name optionally attached to a dashboard invite or dashboard user.
_Avoid_: Username, transaction user ID

**Bootstrap Dashboard Admin**:
The initial dashboard user that can access the first deploy and invite other dashboard users.
_Avoid_: Transaction user, cloud user, regular dashboard user

**Read-only Dashboard User**:
A dashboard user who can view fraud data but cannot create or manage dashboard invites.
_Avoid_: Admin, bootstrap user

## Relationships

- A **Transaction User** can have many transactions and one behavioural profile.
- A **Dashboard User** can view financial data only after being allowed to access the dashboard.
- A **Dashboard User** can authenticate without having a **Dashboard Access Grant**.
- A **Dashboard Invite** can exist before a **Dashboard User** authenticates.
- A **Dashboard Invite** becomes a **Dashboard Access Grant** only for the matching verified email address.
- A **Dashboard Invite** is activated when a Cognito-authenticated dashboard user presents the same verified email address.
- A **Dashboard Access Grant** is required before a **Dashboard User** can view dashboard and API data.
- A disabled **Dashboard Access Grant** rejects the dashboard user until the bootstrap dashboard admin invites the same email again.
- Re-inviting a disabled **Dashboard Access Grant** returns it to a pending invite that must be activated by a matching verified login.
- Dashboard invite and access-grant status belongs to the application, not to the identity provider alone.
- Dashboard API authentication happens before the API handler, while dashboard access-grant checks remain application rules.
- The **Bootstrap Dashboard Admin** is the only dashboard user that can create dashboard access grants in the demo.
- A **Read-only Dashboard User** can view dashboard data but cannot access invite management.
- Dashboard-user administration uses dashboard-scoped language so it is not confused with transaction-user analytics.
- A **Dashboard User** is distinct from a **Transaction User** even when both are represented by user-like identifiers.

## Example dialogue

> **Dev:** "When the dashboard filters by user, is that the authenticated person?"
> **Domain expert:** "No. That is the **Transaction User** being analysed for fraud. The authenticated person is the **Dashboard User**."

## Flagged ambiguities

- "user" was used for both financial transaction subjects and dashboard/API access accounts — resolved: these are separate concepts.
