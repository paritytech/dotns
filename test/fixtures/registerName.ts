import type { NetworkConnection } from 'hardhat/types/network'
import { Address, getAddress, Hex, zeroAddress, zeroHash } from 'viem'
import { EnsStack } from './deployEnsFixture.js'

export type Mutable<T> = {
  -readonly [K in keyof T]: Mutable<T[K]>
}

type RegisterNameOptions = {
  label: string
  ownerAddress?: Address
  duration?: bigint
  secret?: Hex
  resolverAddress?: Address
  data?: Hex[]
  reverseRecord?: ('ethereum' | 'default')[]
  referrer?: Hex
  individualityType?: number
}

const ReverseRecord = {
  ethereum: 1,
  default: 2,
}

// IndividualityType enum values
const IndividualityType = {
  NONE: 0,                  // 9+ chars - first come, first served
  PERSON_LIGHT: 1,          // 6+ chars + .XX (2 digits) - Light verification
  PROOF_OF_PERSONHOOD: 2,   // 6+ chars - Full personhood proof
  GOVERNANCE: 3,            // <6 chars - Governance only
}

// Helper function to determine appropriate individuality type based on label
const getIndividualityTypeForLabel = (label: string): number => {
  // Simple UTF-8 character count
  const charCount = [...label].length

  // Check if it has .XX pattern (a dot + 2 digits at the end)
  const hasPersonLightFormat = /\.\d{2}$/.test(label)

  if (charCount < 6) {
    // Less than 6 chars - Governance (but tests should rarely use this)
    // For testing, we'll allow it, but it may require governance approval
    return IndividualityType.GOVERNANCE
  } else if (charCount >= 6 && charCount <= 8) {
    // 6-8 chars
    if (hasPersonLightFormat) {
      return IndividualityType.PERSON_LIGHT
    } else {
      return IndividualityType.PROOF_OF_PERSONHOOD
    }
  } else {
    // 9+ chars
    return IndividualityType.NONE
  }
}

export const getDefaultRegistrationOptionsWithConnection =
  (connection: NetworkConnection) =>
  async ({
    label,
    ownerAddress,
    duration,
    secret,
    resolverAddress,
    data,
    reverseRecord,
    referrer,
    individualityType,
  }: RegisterNameOptions) => ({
    label,
    ownerAddress: await (async () => {
      if (ownerAddress) return getAddress(ownerAddress)
      const [deployer] = await connection.viem.getWalletClients()
      return getAddress(deployer.account.address)
    })(),
    duration: duration ?? BigInt(60 * 60 * 24 * 365),
    secret:
      secret ??
      '0x0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF',
    resolverAddress: resolverAddress ?? zeroAddress,
    data: data ?? [],
    reverseRecord: reverseRecord ?? [],
    referrer: referrer ?? zeroHash,
    individualityType: individualityType ?? getIndividualityTypeForLabel(label)
  })

export const getRegisterNameParameters = ({
  label,
  ownerAddress,
  duration,
  secret,
  resolverAddress,
  data,
  reverseRecord,
  referrer,
  individualityType,
}: Required<RegisterNameOptions>) => {
  const immutable = {
    label,
    owner: ownerAddress,
    duration,
    secret,
    resolver: resolverAddress,
    data,
    reverseRecord: reverseRecord.reduce(
      (acc, record) => acc | ReverseRecord[record],
      0,
    ),
    referrer,
    individualityType,
  } as const
  return immutable as Mutable<typeof immutable>
}

export const commitNameWithConnection =
  (connection: NetworkConnection) =>
  async (
    { ethRegistrarController }: Pick<EnsStack, 'ethRegistrarController'>,
    params_: RegisterNameOptions,
  ) => {
    const params = await getDefaultRegistrationOptionsWithConnection(
      connection,
    )(params_)
    const args = getRegisterNameParameters(params)

    const testClient = await connection.viem.getTestClient()
    const [deployer] = await connection.viem.getWalletClients()

    const commitmentHash = await ethRegistrarController.read.makeCommitment([
      args,
    ])
    await ethRegistrarController.write.commit([commitmentHash], {
      account: deployer.account,
    })
    const minCommitmentAge =
      await ethRegistrarController.read.minCommitmentAge()
    await testClient.increaseTime({ seconds: Number(minCommitmentAge) })
    await testClient.mine({ blocks: 1 })

    return {
      params,
      args,
      hash: commitmentHash,
    }
  }

export const registerNameWithConnection =
  (connection: NetworkConnection) =>
  async (
    { ethRegistrarController }: Pick<EnsStack, 'ethRegistrarController'>,
    params_: RegisterNameOptions,
  ) => {
    const params = await getDefaultRegistrationOptionsWithConnection(
      connection,
    )(params_)
    const args = getRegisterNameParameters(params)
    const { label, duration } = params

    const testClient = await connection.viem.getTestClient()
    const [deployer] = await connection.viem.getWalletClients()
    const commitmentHash = await ethRegistrarController.read.makeCommitment([
      args,
    ])
    await ethRegistrarController.write.commit([commitmentHash], {
      account: deployer.account,
    })
    const minCommitmentAge =
      await ethRegistrarController.read.minCommitmentAge()
    await testClient.increaseTime({ seconds: Number(minCommitmentAge) })
    await testClient.mine({ blocks: 1 })

    const price = (await ethRegistrarController.read.rentPrice([
      label,
      duration,
    ])) as { base: bigint; premium: bigint }

    const value = price.base + price.premium

    await ethRegistrarController.write.register([args], {
      value,
      account: deployer.account,
    })
  }
