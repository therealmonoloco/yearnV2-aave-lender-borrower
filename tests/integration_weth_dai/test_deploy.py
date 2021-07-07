import pytest
from brownie import chain, Contract, Wei

def test_deploy(vault, dai_whale, yvDAI, strategy, gov, weth, weth_whale, vddai, RELATIVE_APPROX):
    weth.approve(vault, 2 ** 256 - 1, {"from": weth_whale})
    vault.deposit(Wei("20 ether"), {"from": weth_whale})

    strategy.harvest({"from": gov})

    # After first investment sleep for aproximately a year
    chain.sleep(60 * 60 * 24 * 5)
    chain.mine(1)

    dai = Contract(yvDAI.token())
    dai.transfer(yvDAI, Wei("1_600 ether"), {"from": dai_whale})
    print(f"debt balance: {vddai.balanceOf(strategy)/1e18:_}")
    vault.revokeStrategy(strategy)

    vault.setStrategyEnforceChangeLimit(strategy, False, {"from": gov})
    tx = strategy.harvest({"from": gov})

    assert tx.events['Harvested']['profit'] > 0
    assert tx.events['Harvested']['debtPayment'] >= Wei("10 ether")
    #assert tx.events['Harvested']['debtOutstanding'] == 0

    data = vault.strategies(strategy).dict()
    assert data["totalLoss"] == 0
    assert data["totalDebt"] == 0
    assert data["debtRatio"] == 0
    assert yvDAI.balanceOf(strategy) == 0
    assert pytest.approx(vddai.balanceOf(strategy)/1e18, rel=RELATIVE_APPROX) == 0
