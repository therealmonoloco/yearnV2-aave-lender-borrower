import pytest

from brownie import config, chain, interface, Wei, Contract, accounts


@pytest.fixture(autouse=True)
def clean():
    chain.snapshot()
    yield
    chain.revert()


@pytest.fixture(scope="session")
def gov(accounts):
    yield accounts.at("0x05B7D0dfdD845c58AbC8B78b02859b447b79ed34", force=True)


@pytest.fixture(scope="session")
def weth():
    yield Contract("0x7ceB23fD6bC0adD59E62ac25578270cFf1b9f619")


@pytest.fixture(scope="session")
def weth_whale():
    yield accounts.at("0x853ee4b2a13f8a742d64c8f088be7ba2131f670d", force=True)


@pytest.fixture(scope="session")
def yvDAI():
    vault = Contract("0x9cfeb5e00a38ed1c9950dbadc0821ce4cb648a90")
    yield vault


@pytest.fixture(scope="session")
def dai_whale():
    yield accounts.at("0xf04adbf75cdfc5ed26eea4bbbb991db002036bdd", force=True)


@pytest.fixture(scope="class")
def vault(gov):
    yield Contract("0x9ecE944BBcd320F224293117E2780259411D34A3", owner=gov)


@pytest.fixture(scope="session")
def strategist(accounts):
    yield accounts.at("0xaaa8334B378A8B6D8D37cFfEF6A755394B4C89DF", force=True)


@pytest.fixture(scope="class")
def strategy(strategist, vault, Strategy, gov, yvDAI):
    strategy = strategist.deploy(
        Strategy, vault, yvDAI, True, True, "StrategyLenderWethBorrowerDAI"
    )
    vault.addStrategy(strategy, 10_000, 0, 2 ** 256 - 1, 1_000, {"from": gov})
    yield strategy


@pytest.fixture(scope="session")
def RELATIVE_APPROX():
    yield 1e-5
