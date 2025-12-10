import type { NetworkConnection } from 'hardhat/types/network'
import { zeroAddress } from 'viem'

import { DAY } from '../../fixtures/constants.js'
import { toLabelId, toNameId } from '../../fixtures/utils.js'
import {
  CANNOT_SET_RESOLVER,
  CANNOT_UNWRAP,
  CAN_DO_EVERYTHING,
  GRACE_PERIOD,
  IS_DOT_ETH,
  PARENT_CANNOT_CONTROL,
  type LoadNameWrapperFixture,
} from '../fixtures/utils.js'

export const renewTests = (
  connection: NetworkConnection,
  loadNameWrapperFixture: LoadNameWrapperFixture,
) => {
  describe('renew', () => {
    const label = 'register'
    const name = `${label}.dot`

    async function fixture() {
      const initial = await loadNameWrapperFixture()
      const { baseRegistrar, nameWrapper, accounts } = initial

      await baseRegistrar.write.addController([nameWrapper.address])
      await nameWrapper.write.setController([accounts[0].address, true])

      return initial
    }
    const loadFixture = async () =>
      connection.networkHelpers.loadFixture(fixture)

    it('Renews names', async () => {
      const { baseRegistrar, nameWrapper, accounts } = await loadFixture()

      await nameWrapper.write.registerAndWrapETH2LD([
        label,
        accounts[0].address,
        86400n,
        zeroAddress,
        CAN_DO_EVERYTHING,
      ])

      const expires = await baseRegistrar.read.nameExpires([toLabelId(label)])

      await nameWrapper.write.renew([toLabelId(label), 86400n])

      const newExpires = await baseRegistrar.read.nameExpires([
        toLabelId(label),
      ])

      expect(newExpires).toEqual(expires + 86400n)
    })

    it('Renews names and can extend wrapper expiry', async () => {
      const { baseRegistrar, nameWrapper, accounts } = await loadFixture()

      await nameWrapper.write.registerAndWrapETH2LD([
        label,
        accounts[0].address,
        86400n,
        zeroAddress,
        CAN_DO_EVERYTHING,
      ])

      const expires = await baseRegistrar.read.nameExpires([toLabelId(label)])
      const expectedExpiry = expires + 86400n

      await nameWrapper.write.renew([toLabelId(label), 86400n])

      const [owner, , expiry] = await nameWrapper.read.getData([toNameId(name)])

      expect(expiry).toEqual(expectedExpiry + GRACE_PERIOD)
      expect(owner).toEqualAddress(accounts[0].address)
    })

    it('Renewing name less than required to unexpire it still has original owner/fuses', async () => {
      const { nameWrapper, accounts, testClient, publicClient, baseRegistrar } =
        await loadFixture()

      await nameWrapper.write.registerAndWrapETH2LD([
        label,
        accounts[0].address,
        DAY,
        zeroAddress,
        CANNOT_UNWRAP | CANNOT_SET_RESOLVER,
      ])

      // Increase time to 1 minute into grace period (grace period is 5 minutes)
      await testClient.increaseTime({ seconds: Number(DAY + 60n) })
      await testClient.mine({ blocks: 1 })

      const [, , expiryBefore] = await nameWrapper.read.getData([
        toNameId(name),
      ])
      const timestamp = await publicClient.getBlock().then((b) => b.timestamp)
      // NameWrapper stores expiry as baseExpiry + GRACE_PERIOD (90 days)
      // The name is "expired but in grace period" when baseExpiry < timestamp < expiryBefore
      const baseExpiry = expiryBefore - GRACE_PERIOD

      // confirm expired on base registrar but still in wrapper grace period
      expect(baseExpiry).toBeLessThanOrEqual(timestamp)
      expect(timestamp).toBeLessThan(expiryBefore)

      // renew for less than the grace period
      await nameWrapper.write.renew([toLabelId(label), 1n * DAY])

      const [ownerAfter, fusesAfter, expiryAfter] =
        await nameWrapper.read.getData([toNameId(name)])

      expect(ownerAfter).toEqualAddress(accounts[0].address)
      // fuses remain the same
      expect(fusesAfter).toEqual(
        CANNOT_UNWRAP |
          CANNOT_SET_RESOLVER |
          IS_DOT_ETH |
          PARENT_CANNOT_CONTROL,
      )
      // expiry increased by renewal duration (1 DAY)
      // BaseRegistrar adds duration to existing expiry, not current time
      // So new expiry = (baseExpiry + DAY) + GRACE_PERIOD = expiryBefore + DAY
      expect(expiryAfter).toEqual(expiryBefore + DAY)
    })
  })
}
