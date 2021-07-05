import brownie
from brownie import *
from helpers.constants import MaxUint256
from helpers.SnapshotManager import SnapshotManager
from helpers.time import days

"""
  TODO: Put your tests here to prove the strat is good!
  See test_harvest_flow, for the basic tests
  See test_strategy_permissions, for tests at the permissions level
"""


def test_my_custom_test(want, deployer, vault, strategy, aavePool, aaveRewards):
    balance = want.balanceOf(deployer)
    want.approve(vault, balance, {"from": deployer})
    vault.deposit(balance, {"from": deployer})
    vault.earn({"from": deployer})

    chain.sleep(15)
    chain.mine(500)

    cErc20 = Contract.from_explorer(strategy.cErc20())

    assert strategy.balanceOfPool() == cErc20.balanceOf(strategy)

    # If we deposited, then we must have some rewards

    assert aaveRewards.getRewardsBalance([cErc20], strategy) > 0
