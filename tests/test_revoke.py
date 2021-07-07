import pytest
from brownie import Wei, chain


def test_revoke_strategy_from_vault(
    token,
    vault,
    strategy,
    wmatic_whale,
    gov,
    RELATIVE_APPROX,
    vddai,
    amwmatic
):
    assert pytest.approx(strategy.estimatedTotalAssets(), rel=RELATIVE_APPROX) == 0
    amount = Wei("10 ether")
    # Deposit to the vault and harvest
    token.approve(vault, amount, {"from": wmatic_whale})
    vault.deposit(amount, {"from": wmatic_whale})
    chain.sleep(1)
    strategy.harvest()
    assert pytest.approx(strategy.estimatedTotalAssets(), rel=RELATIVE_APPROX) == amount

    vault.revokeStrategy(strategy, {"from": gov})
    chain.sleep(1)
    strategy.harvest()
    assert pytest.approx(token.balanceOf(vault), rel=RELATIVE_APPROX) == amount
    assert vddai.balanceOf(strategy) < Wei("0.5 ether")
    assert amwmatic.balanceOf(strategy) < Wei("0.5 ether")


def test_revoke_strategy_from_strategy(
    token, vault, strategy, wmatic_whale, RELATIVE_APPROX
):
    amount = Wei("10 ether")
    # Deposit to the vault and harvest
    token.approve(vault.address, amount, {"from": wmatic_whale})
    vault.deposit(amount, {"from": wmatic_whale})
    strategy.harvest()
    assert pytest.approx(strategy.estimatedTotalAssets(), rel=RELATIVE_APPROX) == amount

    strategy.setEmergencyExit()
    strategy.harvest()
    assert pytest.approx(token.balanceOf(vault.address), rel=RELATIVE_APPROX) == amount
