// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity ^0.8.24;

import "forge-std/Test.sol";

import { IAuthentication } from "@balancer-labs/v3-interfaces/contracts/solidity-utils/helpers/IAuthentication.sol";
import { IVault } from "@balancer-labs/v3-interfaces/contracts/vault/IVault.sol";

import { BasicAuthorizerMock } from "../../contracts/test/BasicAuthorizerMock.sol";
import { VaultFactory } from "../../contracts/VaultFactory.sol";
import { VaultContractsDeployer } from "./utils/VaultContractsDeployer.sol";
import { Vault } from "../../contracts/Vault.sol";
import { VaultAdmin } from "../../contracts/VaultAdmin.sol";
import { VaultExtension } from "../../contracts/VaultExtension.sol";

contract VaultFactoryTest is Test, VaultContractsDeployer {
    // Should match the "PRODUCTION" limits in BaseVaultTest.
    uint256 private constant _MIN_TRADE_AMOUNT = 1e6;
    uint256 private constant _MIN_WRAP_AMOUNT = 1e4;
    bytes32 private constant _HARDCODED_SALT =
        bytes32(0xae0bdc4eeac5e950b67c6819b118761caaf619464ad74a6048c67c03598dc543);
    address private constant _HARDCODED_VAULT_ADDRESS = address(0xbA133381ef63946fF77A7D009DFcdBdE5c77b92F);

    address deployer;
    BasicAuthorizerMock authorizer;
    VaultFactory factory;

    function setUp() public virtual {
        deployer = makeAddr("deployer");
        authorizer = deployBasicAuthorizerMock();
        vm.prank(deployer);
        factory = deployVaultFactory(
            authorizer,
            90 days,
            30 days,
            _MIN_TRADE_AMOUNT,
            _MIN_WRAP_AMOUNT,
            keccak256(type(Vault).creationCode),
            keccak256(type(VaultAdmin).creationCode),
            keccak256(type(VaultExtension).creationCode)
        );
    }

    function testCreateVaultHardcodedSalt() public {
        authorizer.grantRole(factory.getActionId(VaultFactory.create.selector), deployer);
        vm.prank(deployer);
        factory.create(
            HARDCODED_SALT,
            HARDCODED_VAULT_ADDRESS,
            type(Vault).creationCode,
            type(VaultAdmin).creationCode,
            type(VaultExtension).creationCode
        );
    }

    function testCreateVaultHardcodedSaltWrongDeployer() public {
        address wrongDeployer = makeAddr("wrongDeployer");
        vm.prank(wrongDeployer);
        VaultFactory wrongFactory = deployVaultFactory(
            authorizer,
            90 days,
            30 days,
            _MIN_TRADE_AMOUNT,
            _MIN_WRAP_AMOUNT,
            keccak256(type(Vault).creationCode),
            keccak256(type(VaultAdmin).creationCode),
            keccak256(type(VaultExtension).creationCode)
        );

        authorizer.grantRole(wrongFactory.getActionId(VaultFactory.create.selector), wrongDeployer);
        vm.prank(wrongDeployer);
        vm.expectRevert(VaultFactory.VaultAddressMismatch.selector);
        wrongFactory.create(
            HARDCODED_SALT,
            HARDCODED_VAULT_ADDRESS,
            type(Vault).creationCode,
            type(VaultAdmin).creationCode,
            type(VaultExtension).creationCode
        );
    }

    /// forge-config: default.fuzz.runs = 100
    function testCreateVault__Fuzz(bytes32 salt) public {
        authorizer.grantRole(factory.getActionId(VaultFactory.create.selector), deployer);

        address vaultAddress = factory.getDeploymentAddress(salt);
        vm.prank(deployer);
        factory.create(
            salt,
            vaultAddress,
            type(Vault).creationCode,
            type(VaultAdmin).creationCode,
            type(VaultExtension).creationCode
        );

        // We cannot compare the deployed bytecode of the created vault against a second deployment of the Vault
        // because the actionIdDisambiguator of the authentication contract is stored in immutable storage.
        // Therefore such comparison would fail, so we just call a few getters instead.
        IVault vault = IVault(vaultAddress);
        assertEq(address(vault.getAuthorizer()), address(authorizer));

        (bool isPaused, uint32 pauseWindowEndTime, uint32 bufferWindowEndTime) = vault.getVaultPausedState();
        assertEq(isPaused, false);
        assertEq(pauseWindowEndTime, block.timestamp + 90 days, "Wrong pause window end time");
        assertEq(bufferWindowEndTime, block.timestamp + 90 days + 30 days, "Wrong buffer window end time");
    }

    function testCreateNotAuthorized() public {
        vm.prank(deployer);
        vm.expectRevert(IAuthentication.SenderNotAllowed.selector);
        factory.create(
            bytes32(0),
            address(0),
            type(Vault).creationCode,
            type(VaultAdmin).creationCode,
            type(VaultExtension).creationCode
        );
    }

    function testCreateMismatch() public {
        bytes32 salt = bytes32(uint256(123));
        authorizer.grantRole(factory.getActionId(VaultFactory.create.selector), deployer);

        address vaultAddress = factory.getDeploymentAddress(salt);
        vm.prank(deployer);
        vm.expectRevert(VaultFactory.VaultAddressMismatch.selector);
        factory.create(
            bytes32(uint256(salt) + 1),
            vaultAddress,
            type(Vault).creationCode,
            type(VaultAdmin).creationCode,
            type(VaultExtension).creationCode
        );
    }

    function testCreateTwice() public {
        bytes32 salt = bytes32(uint256(123));
        authorizer.grantRole(factory.getActionId(VaultFactory.create.selector), deployer);

        address vaultAddress = factory.getDeploymentAddress(salt);
        vm.startPrank(deployer);
        factory.create(
            salt,
            vaultAddress,
            type(Vault).creationCode,
            type(VaultAdmin).creationCode,
            type(VaultExtension).creationCode
        );
        vm.expectRevert();
        factory.create(
            salt,
            vaultAddress,
            type(Vault).creationCode,
            type(VaultAdmin).creationCode,
            type(VaultExtension).creationCode
        );
    }

    function testInvalidVaultBytecode() public {
        bytes32 salt = bytes32(uint256(123));
        authorizer.grantRole(factory.getActionId(VaultFactory.create.selector), deployer);

        address vaultAddress = factory.getDeploymentAddress(salt);
        vm.prank(deployer);
        vm.expectRevert(abi.encodeWithSelector(VaultFactory.InvalidBytecode.selector, "Vault"));
        factory.create(
            salt,
            vaultAddress,
            new bytes(0),
            type(VaultAdmin).creationCode,
            type(VaultExtension).creationCode
        );
    }

    function testInvalidVaultAdminBytecode() public {
        bytes32 salt = bytes32(uint256(123));
        authorizer.grantRole(factory.getActionId(VaultFactory.create.selector), deployer);

        address vaultAddress = factory.getDeploymentAddress(salt);
        vm.prank(deployer);
        vm.expectRevert(abi.encodeWithSelector(VaultFactory.InvalidBytecode.selector, "VaultAdmin"));
        factory.create(salt, vaultAddress, type(Vault).creationCode, new bytes(0), type(VaultExtension).creationCode);
    }

    function testInvalidVaultExtensionBytecode() public {
        bytes32 salt = bytes32(uint256(123));
        authorizer.grantRole(factory.getActionId(VaultFactory.create.selector), deployer);

        address vaultAddress = factory.getDeploymentAddress(salt);
        vm.prank(deployer);
        vm.expectRevert(abi.encodeWithSelector(VaultFactory.InvalidBytecode.selector, "VaultExtension"));
        factory.create(salt, vaultAddress, type(Vault).creationCode, type(VaultAdmin).creationCode, new bytes(0));
    }
}
