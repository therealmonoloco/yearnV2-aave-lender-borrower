import pytest

from brownie import config, chain, interface, Wei
from brownie import Contract


@pytest.fixture(autouse=True)
def clean():
    chain.snapshot()
    yield
    chain.revert()


@pytest.fixture(scope="session")
def gov(accounts):
    vault = Contract("0xCcba0B868106d55704cb7ff19782C829dc949feB")
    yield accounts.at(vault.governance(), force=True)


@pytest.fixture(scope="session")
def yvDAI():
    vault = Contract("0x9cfeb5e00a38ed1c9950dbadc0821ce4cb648a90")
    yield vault


@pytest.fixture(scope="session")
def wmatic():
    yield Contract("0x0d500b1d8e8ef31e21c99d1db9a6444d3adf1270")


@pytest.fixture(scope="session")
def dai():
    yield Contract("0x8f3cf7ad23cd3cadbd9735aff958023239c6a063")


@pytest.fixture(scope="session")
def vddai():
    yield interface.IVariableDebtToken("0x75c4d1fb84429023170086f06e682dcbbf537b7d")


@pytest.fixture(scope="session")
def amwmatic():
    yield interface.IAToken("0x8df3aad3a84da6b69a4da8aec3ea40d9091b2ac4")


@pytest.fixture(scope="session")
def wmatic_whale(accounts):
    yield accounts.at("0x2bb25175d9b0f8965780209eb558cc3b56ca6d32", force=True)


@pytest.fixture(scope="session")
def dai_whale(accounts):
    yield accounts.at("0x27f8d03b3a2196956ed754badc28d73be8830a6e", force=True)


@pytest.fixture(scope="class")
def vault(gov):
    yield Contract("0xCcba0B868106d55704cb7ff19782C829dc949feB", owner=gov)


@pytest.fixture(scope="class")
def strategy(strategist, vault, Strategy, gov, yvDAI):
    strategy = strategist.deploy(
        Strategy, vault, yvDAI, True, True, "StrategyLenderWMATICBorrowerDAI"
    )
    vault.addStrategy(strategy, 200, 0, 2 ** 256 - 1, 1_000, {"from": gov})
    yield strategy
