## Circles Invitation Escrow

Circles Invitation Escrow contract holds CRC for inviter that can later be redeemed by invitee to register as human.

## Dev

### Build

```shell
$ forge build
```

### Test

```shell
$ forge test
```

### Format

```shell
$ forge fmt
```

### Deploy

```shell
$ forge script script/InvitationEscrow.s.sol:InvitationEscrowScript --rpc-url $GNOSIS_RPC --private-key <your_private_key>
```

## How it works

The InvitationEscrow contract manages Circles (CRC) token invitations between registered humans (inviters) and unregistered users (invitees). It applies demurrage over time and handles invitation redemption and revocation.

### Core Concepts

- **Inviter**: Must be a registered human in HubV2 with CRC tokens
- **Invitee**: Must be unregistered (not yet human) to receive invitations
- **Escrow Amount**: Between 97-100 CRC tokens per invitation
- **Demurrage**: Token value decreases over time (Check Demurrage.sol)
- **Trust Requirement**: Inviter must first trust invitee for invitation to work

### Callflow

#### 1. Create Invitation

**Function**: `HubV2.safeTransferFrom(inviter, escrowContract, tokenId, amount, abi.encode(invitee))`  
**Function Caller**: Inviter

**Requirements**:

- Inviter must be registered human (`isHuman(inviter)`)
- Amount between `MIN_CRC_AMOUNT` (97 CRC) and `MAX_CRC_AMOUNT` (100 CRC)
- Invitee must not be registered (`avatars(invitee) == 0`)
- Trust must exist between inviter and invitee (`isTrusted(inviter, invitee)`)
- No existing escrow between this inviter-invitee pair

**Result**:

- CRC tokens locked in escrow contract
- Bidirectional linked list entries created (inviter→invitee and invitee→inviter)
- `InvitationEscrowed` event emitted
- Demurrage tracking begins

```mermaid
sequenceDiagram
    participant Inviter
    participant HubV2
    participant InvitationEscrow

    Inviter->>HubV2: safeTransferFrom(inviter, escrow, tokenId, amount, encodedInvitee)
    HubV2->>InvitationEscrow: onERC1155Received(operator, from, id, value, data)

    Note over InvitationEscrow: ✅ caller is HubV2
    Note over InvitationEscrow: ✅ inviter is registered human
    Note over InvitationEscrow: ✅ amount is 97-100 CRC
    Note over InvitationEscrow: ✅ invitee is not registered
    Note over InvitationEscrow: ✅ no existing escrow exists
    Note over InvitationEscrow: ✅ inviter trusted invitee

    Note over InvitationEscrow: Setup escrowedAmount[inviter][invitee]
    Note over InvitationEscrow: Setup [inviter][invitee] linked list
    Note over InvitationEscrow: InvitationEscrowed event

    InvitationEscrow->>HubV2: Return onERC1155Received selector
```

#### 2. Redeem Invitation

**Function**: `invitationEscrow.redeemInvitation(inviter)`  
**Function Caller**: Invitee

**Requirements**:

- Valid escrow must exist between inviter and invitee
- Trust must still be valid (`isTrusted(inviter, invitee)`)

**Result**:

- All invitations for the invitee are processed:
  - Selected inviter receives their original CRC tokens (ERC1155)
  - Other inviters receive demurrage ERC20 tokens as refunds
- All escrow records deleted and linked lists updated
- `InvitationRedeemed` event for selected inviter
- `InvitationRefunded` events for other inviters
- Invitee can now register as human using the CRC tokens by calling `HubV2.registerHuman(inviter)`

```mermaid
sequenceDiagram
    participant Invitee
    participant InvitationEscrow
    participant HubV2
    participant SelectedInviter
    participant OtherInviter

    Invitee->>InvitationEscrow: redeemInvitation(selectedInviter)

    Note over InvitationEscrow: Validation:
    Note over InvitationEscrow: ✅ escrow exists
    Note over InvitationEscrow: ✅ isTrusted(selectedInviter, invitee)


    loop For each inviter in linked list
        InvitationEscrow->>InvitationEscrow: _revokeInvitation(inviter, invitee)
        InvitationEscrow->>InvitationEscrow: Calculate demurrage amount

        alt inviter == selectedInviter
            InvitationEscrow->>HubV2: safeTransferFrom(escrow, selectedInviter, tokenId, amount, "")

            HubV2->>SelectedInviter: Gets original ERC1155 tokens
            Note over InvitationEscrow: InvitationRedeemed event
        else other inviter
            InvitationEscrow->>InvitationEscrow: _wrapAndTransfer(otherInviter, demurrageAmount)
            InvitationEscrow->>HubV2: wrap(otherInviter, amount, type: Demurrage)
            InvitationEscrow->>OtherInviter: transfer(demurrageERC20, amount)
            Note over InvitationEscrow: InvitationRefunded event
        end
    end

    Note over InvitationEscrow: All escrows deleted
    Note over InvitationEscrow: All linked lists updated

    Note over Invitee: Can now call:
    Invitee->>HubV2: registerHuman(selectedInviter, proof)
```

#### 3. Revoke Single Invitation

**Function**: `invitationEscrow.revokeInvitation(invitee)`  
**Function Caller**: Inviter

**Requirements**:

- Active escrow must exist between inviter and invitee

**Result**:

- Escrow deleted and linked list entries removed
- Inviter receives demurrage ERC20 token
- `InvitationRevoked` event emitted

```mermaid
sequenceDiagram
    participant Inviter
    participant InvitationEscrow
    participant HubV2

    Inviter->>InvitationEscrow: revokeInvitation(invitee)

    Note over InvitationEscrow: Validation:
    Note over InvitationEscrow: ✅ escrow exists for pair
    Note over InvitationEscrow: Delete [inviter][invitee] linked list


    InvitationEscrow->>InvitationEscrow: _wrapAndTransfer(inviter, amount)
    InvitationEscrow->>HubV2: wrap(inviter, amount, type: Demurrage)
    InvitationEscrow->>Inviter: transfer(demurrageERC20, amount)

    Note over InvitationEscrow: InvitationRevoked event
    Note over Inviter: ✓ Receives demurrage ERC20

```

#### 4. Revoke All Invitations

**Function**: `invitationEscrow.revokeAllInvitations()`  
**Function Caller**: Inviter

**Result**:

- All inviter's escrows are revoked
- Total demurrage ERC20 and transferred to inviter
- Individual `InvitationRevoked` events for each invitee

```mermaid
sequenceDiagram
    participant Inviter
    participant InvitationEscrow
    participant HubV2

    Inviter->>InvitationEscrow: revokeAllInvitations()

    loop For each invitee in inviter's list
        Note over InvitationEscrow: Get next invitee from linked list

        InvitationEscrow->>InvitationEscrow: _revokeInvitation(inviter, invitee)

        Note over InvitationEscrow: Get balance from HubV2
        Note over InvitationEscrow: Get revokedAmount from InvitationEscrow

        alt balance >= revokedAmount
            InvitationEscrow->>InvitationEscrow: balance -= revokedAmount
            InvitationEscrow->>InvitationEscrow: totalAmount += revokedAmount
        else balance < revokedAmount
            InvitationEscrow->>InvitationEscrow: revokedAmount = balance
            InvitationEscrow->>InvitationEscrow: balance = 0
            InvitationEscrow->>InvitationEscrow: totalAmount += revokedAmount
        end
        Note over InvitationEscrow:  InvitationRevoked event
    end

    InvitationEscrow->>InvitationEscrow: _wrapAndTransfer(inviter, totalAmount)
    InvitationEscrow->>HubV2: wrap(inviter, totalAmount, demurrageType)
    InvitationEscrow->>Inviter: transfer(demurrageERC20, totalAmount)

    Note over InvitationEscrow: ✓ All escrows deleted
    Note over InvitationEscrow: ✓ All linked lists updated
    Note over Inviter: ✓ Receives total demurrage ERC20
```

### View Functions

- `getInviters(invitee)`: Returns all active inviters for an invitee
- `getInvitees(inviter)`: Returns all active invitees for an inviter
- `getEscrowedAmountAndDays(inviter, invitee)`: Returns current demurrage-adjusted balance and days elapsed

### Edge Cases & Safeguards

1. **Balance Mismatches**: Hub balance may differ from escrow calculations.
   - **Solution**: Choose the smaller amount(`_capToHubBalance`).
2. **Trust Expiration**: Trust may expire between invitation and redemption
   - **Result**: `MissingOrExpiredTrust` error on redemption attempt
3. **Zero Balance After Demurrage**: Long-term escrows may decay to zero
   - **Result**: Unable to redeem invitation and requires new transfer.
