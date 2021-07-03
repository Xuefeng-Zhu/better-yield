import pytest
from brownie import config
from brownie import Contract


@pytest.fixture
def gov(accounts):
    yield accounts.at("0xFEB4acf3df3cDEA7399794D0869ef76A6EfAff52", force=True)


@pytest.fixture
def user(accounts):
    yield accounts[0]


@pytest.fixture
def rewards(accounts):
    yield accounts[1]


@pytest.fixture
def guardian(accounts):
    yield accounts[2]


@pytest.fixture
def management(accounts):
    yield accounts[3]


@pytest.fixture
def strategist(accounts):
    yield accounts[4]


@pytest.fixture
def keeper(accounts):
    yield accounts[5]


@pytest.fixture
def token():
    # this should be the address of the ERC-20 used by the strategy/vault (DAI)
    token_address = "0x5f98805A4E8be255a32880FDeC7F6728C6568bA0"
    yield Contract(token_address)


@pytest.fixture
def amount(accounts, token, user):
    amount = 10_000 * 10 ** token.decimals()
    # In order to get some funds for the token you are about to use,
    # it impersonate an exchange address to use it's funds.
    reserve = accounts.at(
        "0x7931cb92c651f6a0c3cd5d5d188acad92c0bec51", force=True)
    token.transfer(user, amount, {"from": reserve})
    yield amount


@pytest.fixture
def weth():
    token_address = "0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2"
    yield Contract(token_address)


@pytest.fixture
def weth_amout(user, weth):
    weth_amout = 10 ** weth.decimals()
    user.transfer(weth, weth_amout)
    yield weth_amout


@pytest.fixture
def vault(pm, gov, rewards, guardian, management, token):
    Vault = pm(config["dependencies"][0]).Vault
    vault = guardian.deploy(Vault)
    vault.initialize(token, gov, rewards, "", "", guardian, management)
    vault.setDepositLimit(2 ** 256 - 1, {"from": gov})
    vault.setManagement(management, {"from": gov})
    yield vault


@pytest.fixture
def strategy(strategist, keeper, vault, Strategy, gov):
    weth = Contract("0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D", owner=gov)
    lusd = Contract("0x5f98805A4E8be255a32880FDeC7F6728C6568bA0", owner=gov)
    dai_idle = Contract(
        "0x3fE7940616e5Bc47b0775a0dccf6237893353bB4", owner=gov)
    dmm_router = Contract(
        "0x1c87257f5e8609940bc751a07bb085bb7f8cdbe6", owner=gov)
    uni_router = Contract(
        "0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D", owner=gov)
    umbrella = Contract(
        "0xAed0c38402a5d19df6E4c03F4E2DceD6e29c1ee9", owner=gov)
    dai_feed = Contract(
        "0xAed0c38402a5d19df6E4c03F4E2DceD6e29c1ee9", owner=gov)
    eth_feed = Contract(
        "0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419", owner=gov)

    strategy = strategist.deploy(
        Strategy, vault, lusd, weth, dai_idle, uni_router, dmm_router, umbrella, dai_feed, eth_feed)
    strategy.setKeeper(keeper)
    vault.addStrategy(strategy, 10_000, 0, 2 ** 256 - 1, 1_000, {"from": gov})
    yield strategy


@pytest.fixture(scope="session")
def RELATIVE_APPROX():
    yield 1e-5
