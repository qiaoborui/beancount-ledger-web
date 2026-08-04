import pytest

from ledger_agent_service.onboarding import _validate_account, default_draft, is_ready, normalize_draft


def test_onboarding_draft_defaults() -> None:
    draft = normalize_draft(None)
    assert draft["currency"] == "CNY"
    assert draft["fundingSpaces"] == []


def test_onboarding_ready_requires_three_sections() -> None:
    draft = default_draft()
    assert not is_ready(draft)
    draft["fundingSpaces"].append({"name": "现金"})
    draft["incomeCategories"].append({"templateKey": "salary"})
    draft["expenseCategories"].append({"templateKey": "dining"})
    assert is_ready(draft)


def test_onboarding_accounts_are_bound_to_the_exact_kind_prefix() -> None:
    assert _validate_account("Assets:Wallet:WeChat", "Assets:Wallet") == "Assets:Wallet:WeChat"
    with pytest.raises(ValueError):
        _validate_account("Assets:Bank:WeChat", "Assets:Wallet")
