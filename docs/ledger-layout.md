# Ledger layout

The app expects `LEDGER_ROOT` to point to a Beancount ledger directory.

Minimum structure:

```text
main.bean
accounts.bean
commodities.bean
budgets.bean
prices.bean
transactions/
```

Example `main.bean`:

```beancount
option "title" "My Beancount Ledger"
option "operating_currency" "CNY"
option "booking_method" "FIFO"

include "commodities.bean"
include "accounts.bean"
include "budgets.bean"
include "prices.bean"
include "transactions/2026.bean"
```

Accounts are loaded from `accounts.bean`. AI-generated entries are validated against active accounts from this file.

Transactions can be organized however you prefer as long as they are included from `main.bean`. New Web writes currently append to `transactions/YYYY.bean`.
