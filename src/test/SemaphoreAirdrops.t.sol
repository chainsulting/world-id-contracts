// SPDX-License-Identifier: MIT
pragma solidity ^0.8.10;

import { Vm } from 'forge-std/Vm.sol';
import { DSTest } from 'ds-test/test.sol';
import { Semaphore } from '../Semaphore.sol';
import { TestERC20, ERC20 } from './mock/TestERC20.sol';
import { TypeConverter } from './utils/TypeConverter.sol';
import { SemaphoreAirdrops } from '../SemaphoreAirdrops.sol';

contract User {}

contract SemaphoreAirdropsTest is DSTest {
    using TypeConverter for address;

    event AirdropClaimed(uint256 indexed airdropId, address receiver);
    event AirdropCreated(uint256 airdropId, SemaphoreAirdrops.Airdrop airdrop);
    event AirdropUpdated(uint256 indexed airdropId, SemaphoreAirdrops.Airdrop airdrop);

    User internal user;
    uint256 internal groupId;
    TestERC20 internal token;
    Semaphore internal semaphore;
    SemaphoreAirdrops internal airdrop;
    Vm internal hevm = Vm(HEVM_ADDRESS);

    function setUp() public {
        groupId = 1;
        user = new User();
        token = new TestERC20();
        semaphore = new Semaphore();
        airdrop = new SemaphoreAirdrops(semaphore);

        hevm.label(address(this), 'Sender');
        hevm.label(address(user), 'Holder');
        hevm.label(address(token), 'Token');
        hevm.label(address(semaphore), 'Semaphore');
        hevm.label(address(airdrop), 'SemaphoreAirdrops');

        // Issue some tokens to the user address, to be airdropped from the contract
        token.issue(address(user), 10 ether);

        // Approve spending from the airdrop contract
        hevm.prank(address(user));
        token.approve(address(airdrop), type(uint256).max);
    }

    function genIdentityCommitment() internal returns (uint256) {
        string[] memory ffiArgs = new string[](2);
        ffiArgs[0] = 'node';
        ffiArgs[1] = 'src/test/scripts/generate-commitment.js';

        bytes memory returnData = hevm.ffi(ffiArgs);
        return abi.decode(returnData, (uint256));
    }

    function genProof() internal returns (uint256, uint256[8] memory proof) {
        string[] memory ffiArgs = new string[](5);
        ffiArgs[0] = 'node';
        ffiArgs[1] = '--no-warnings';
        ffiArgs[2] = 'src/test/scripts/generate-proof.js';
        ffiArgs[3] = address(airdrop).toString();
        ffiArgs[4] = address(this).toString();

        bytes memory returnData = hevm.ffi(ffiArgs);

        return abi.decode(returnData, (uint256, uint256[8]));
    }

    function testCanCreateAirdrop() public {
        hevm.expectEmit(false, false, false, true);
        emit AirdropCreated(1, SemaphoreAirdrops.Airdrop({
            groupId: groupId,
            token: token,
            manager: address(this),
            holder: address(user),
            amount: 1 ether
        }));
        airdrop.createAirdrop(groupId, token, address(user), 1 ether);

        (uint256 _groupId, ERC20 _token, address manager, address _holder, uint256 amount) = airdrop.getAirdrop(1);

        assertEq(_groupId, groupId);
        assertEq(address(_token), address(token));
        assertEq(manager, address(this));
        assertEq(_holder, address(user));
        assertEq(amount, 1 ether);
    }

    function testCanClaim() public {
        assertEq(token.balanceOf(address(this)), 0);

        airdrop.createAirdrop(groupId, token, address(user), 1 ether);
        semaphore.createGroup(groupId, 20, 0);
        semaphore.addMember(groupId, genIdentityCommitment());

        (uint256 nullifierHash, uint256[8] memory proof) = genProof();
        uint256 root = semaphore.getRoot(groupId);

        hevm.expectEmit(true, false, false, true);
        emit AirdropClaimed(1, address(this));
        airdrop.claim(1, address(this), root, nullifierHash, proof);

        assertEq(token.balanceOf(address(this)), 1 ether);
    }

    function testCanClaimAfterNewMemberAdded() public {
        assertEq(token.balanceOf(address(this)), 0);

        airdrop.createAirdrop(groupId, token, address(user), 1 ether);
        semaphore.createGroup(groupId, 20, 0);
        semaphore.addMember(groupId, genIdentityCommitment());
        uint256 root = semaphore.getRoot(groupId);
        semaphore.addMember(groupId, 1);

        (uint256 nullifierHash, uint256[8] memory proof) = genProof();
        airdrop.claim(1, address(this), root, nullifierHash, proof);

        assertEq(token.balanceOf(address(this)), 1 ether);
    }

    function testCannotClaimHoursAfterNewMemberAdded() public {
        assertEq(token.balanceOf(address(this)), 0);

        airdrop.createAirdrop(groupId, token, address(user), 1 ether);
        semaphore.createGroup(groupId, 20, 0);
        semaphore.addMember(groupId, genIdentityCommitment());
        uint256 root = semaphore.getRoot(groupId);
        semaphore.addMember(groupId, 1);

        hevm.warp(block.timestamp + 2 hours);

        (uint256 nullifierHash, uint256[8] memory proof) = genProof();
        hevm.expectRevert(Semaphore.InvalidRoot.selector);
        airdrop.claim(1, address(this), root, nullifierHash, proof);

        assertEq(token.balanceOf(address(this)), 0);
    }

    function testCannotDoubleClaim() public {
        assertEq(token.balanceOf(address(this)), 0);

        airdrop.createAirdrop(groupId, token, address(user), 1 ether);
        semaphore.createGroup(groupId, 20, 0);
        semaphore.addMember(groupId, genIdentityCommitment());

        (uint256 nullifierHash, uint256[8] memory proof) = genProof();
        airdrop.claim(1, address(this), semaphore.getRoot(groupId), nullifierHash, proof);

        assertEq(token.balanceOf(address(this)), 1 ether);

        uint256 root = semaphore.getRoot(groupId);
        hevm.expectRevert(SemaphoreAirdrops.InvalidNullifier.selector);
        airdrop.claim(1, address(this), root, nullifierHash, proof);

        assertEq(token.balanceOf(address(this)), 1 ether);
    }

    function testCannotClaimIfNotMember() public {
        assertEq(token.balanceOf(address(this)), 0);

        airdrop.createAirdrop(groupId, token, address(user), 1 ether);
        semaphore.createGroup(groupId, 20, 0);
        semaphore.addMember(groupId, 1);

        uint256 root = semaphore.getRoot(groupId);
        (uint256 nullifierHash, uint256[8] memory proof) = genProof();

        hevm.expectRevert(abi.encodeWithSignature('InvalidProof()'));
        airdrop.claim(1, address(this), root, nullifierHash, proof);

        assertEq(token.balanceOf(address(this)), 0);
    }

    function testCannotClaimWithInvalidSignal() public {
        assertEq(token.balanceOf(address(this)), 0);

        airdrop.createAirdrop(groupId, token, address(user), 1 ether);
        semaphore.createGroup(groupId, 20, 0);
        semaphore.addMember(groupId, genIdentityCommitment());

        (uint256 nullifierHash, uint256[8] memory proof) = genProof();

        uint256 root = semaphore.getRoot(groupId);
        hevm.expectRevert(abi.encodeWithSignature('InvalidProof()'));
        airdrop.claim(1, address(user), root, nullifierHash, proof);

        assertEq(token.balanceOf(address(this)), 0);
    }

    function testCannotClaimWithInvalidProof() public {
        assertEq(token.balanceOf(address(this)), 0);

        airdrop.createAirdrop(groupId, token, address(user), 1 ether);
        semaphore.createGroup(groupId, 20, 0);
        semaphore.addMember(groupId, genIdentityCommitment());

        (uint256 nullifierHash, uint256[8] memory proof) = genProof();
        proof[0] ^= 42;

        uint256 root = semaphore.getRoot(groupId);
        hevm.expectRevert(abi.encodeWithSignature('InvalidProof()'));
        airdrop.claim(1, address(this), root, nullifierHash, proof);

        assertEq(token.balanceOf(address(this)), 0);
    }
}