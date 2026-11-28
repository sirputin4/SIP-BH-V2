# SIP-BH V2 — Architecture and workflow

## Deployment architecture

```mermaid
flowchart TD
  U1[Admin Kanwil browser] --> GH[GitHub Pages: React application]
  U2[PBH browser] --> GH
  GH -->|HTTPS API + Auth| SB[Supabase]
  SB --> AUTH[Supabase Auth]
  SB --> DB[(PostgreSQL + RLS)]
  SB --> STORE[Private Storage]
  DB --> DASH[Dashboard and CSV recaps]
```

GitHub Pages hosts static frontend files only. Supabase provides authentication, database APIs and private file storage. No Node.js server process or direct PostgreSQL pooler connection is required for browser users.

## Data relationship

```mermaid
erDiagram
  OBHS ||--o{ PROFILES : accounts
  OBHS ||--o{ OBH_MEMBERS : has
  OBHS ||--o{ BENEFICIARIES : serves
  BENEFICIARIES ||--o{ ASSISTANCE_SERVICES : receives
  OBHS ||--o{ ASSISTANCE_SERVICES : provides
  ASSISTANCE_SERVICES ||--o{ SERVICE_PROGRESS : tracks
  ASSISTANCE_SERVICES ||--o| SERVICE_EVALUATIONS : evaluated
  SERVICE_EVALUATIONS ||--o{ EVALUATION_SCORES : scores
  OBHS ||--o{ REPORT_SUBMISSIONS : submits
```

## Service entry and review flow

```mermaid
flowchart TD
  A[PBH or Admin creates beneficiary/service] --> B[Select Litigasi or Nonlitigasi]
  B --> C[Record service details and amount]
  C --> D[Add progress history]
  D --> E{Who entered it?}
  E -->|PBH| F[Submitted for Admin verification]
  E -->|Admin| G[Admin-created record]
  F --> H{Admin review}
  H -->|Verified| I[Verified service]
  H -->|Revision| J[PBH corrects record]
  J --> F
  H -->|Rejected| K[Rejected with reason]
  G --> I
  I --> L[Dashboard, periodic recap and evaluation]
```

## Roles

| Capability | Admin Kanwil | PBH |
|---|---|---|
| View PBH directory | All | Active directory and own organization |
| Manage accreditation | Yes | No |
| Manage own contact/personnel | Yes | Yes, own organization |
| Register beneficiary | Any PBH | Own PBH |
| Create service record | Any PBH | Own PBH |
| Add progress | All records | Own records |
| Verify service/report | Yes | No |
| Evaluate service | Yes | Read own results |
| Upload periodic report | Yes | Own PBH |

## Security boundaries

- Supabase Auth identifies the current user.
- `profiles.role`, `profiles.account_status` and `profiles.obh_id` determine the user's scope.
- Row Level Security (RLS) is enabled on the application tables.
- The browser only receives the public publishable/anon key; privileged secret keys are never used client-side.
- The Storage bucket for reports is private and accessed through signed URLs.
- Sensitive beneficiary fields require additional institutional privacy controls before real-world use.
