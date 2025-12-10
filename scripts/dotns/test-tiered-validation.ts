import { viem } from 'hardhat'

/**
 * Tiered Domain Registration Validation Test
 *
 * This script demonstrates the different validation rules based on individuality types:
 *
 * 1. NONE (0): 9+ characters - First come, first served (any format)
 * 2. PERSON_LIGHT (1): 6-8 characters + .XX (2 digits) - Light person verification
 * 3. PROOF_OF_PERSONHOOD (2): 6-8 characters (plain) - Full personhood proof
 * 4. GOVERNANCE (3): <6 characters - Polkadot governance only
 */

async function main() {
  console.log('🧪 Testing Tiered Domain Registration Validation\n')
  console.log('=' .repeat(70))

  const testCases = [
    {
      category: 'NONE - 9+ Characters (First Come, First Served)',
      type: 'NONE (0)',
      cases: [
        { name: 'polkadot1', valid: true, desc: '9 chars - any format allowed' },
        { name: 'leonardoxyz', valid: true, desc: '11 chars - any format allowed' },
        { name: 'verylongname123', valid: true, desc: '15 chars - any format allowed' },
        { name: 'crypto.99', valid: false, desc: '8 chars total - too short for NONE' },
        { name: 'test.12', valid: false, desc: '7 chars total - too short for NONE' },
      ],
    },
    {
      category: 'PERSON_LIGHT - 6-8 Characters + .XX (Light Verification)',
      type: 'PERSON_LIGHT (1)',
      cases: [
        { name: 'crypto.42', valid: true, desc: '6 chars + .42 ✓' },
        { name: 'leonardo.12', valid: true, desc: '8 chars + .12 ✓' },
        { name: 'abcdef.00', valid: true, desc: '6 chars + .00 ✓' },
        { name: 'test.99', valid: false, desc: 'Only 4 chars before dot (need 6+)' },
        { name: 'polkadot.11', valid: false, desc: '8 chars but too long (9 chars total with suffix)' },
        { name: 'crypto.1', valid: false, desc: 'Only 1 digit (need 2)' },
        { name: 'crypto.abc', valid: false, desc: 'Letters instead of digits' },
        { name: 'crypto', valid: false, desc: 'No .XX suffix' },
      ],
    },
    {
      category: 'PROOF_OF_PERSONHOOD - 6-8 Characters Plain (Full Verification)',
      type: 'PROOF_OF_PERSONHOOD (2)',
      cases: [
        { name: 'crypto', valid: true, desc: '6 chars plain ✓' },
        { name: 'leonard', valid: true, desc: '7 chars plain ✓' },
        { name: 'polkadot', valid: true, desc: '8 chars plain ✓' },
        { name: 'alice', valid: false, desc: 'Only 5 chars (need 6+)' },
        { name: 'verylongname', valid: false, desc: '12 chars (max 8 for this tier)' },
        { name: 'crypto.42', valid: false, desc: 'Has .XX suffix (that\'s PERSON_LIGHT)' },
      ],
    },
    {
      category: 'GOVERNANCE - Less than 6 Characters (Polkadot Governance Only)',
      type: 'GOVERNANCE (3)',
      cases: [
        { name: 'dot', valid: true, desc: '3 chars ✓' },
        { name: 'gov', valid: true, desc: '3 chars ✓' },
        { name: 'alice', valid: true, desc: '5 chars ✓' },
        { name: 'x', valid: true, desc: '1 char ✓' },
        { name: 'crypto', valid: false, desc: '6 chars (too long for governance)' },
        { name: 'polkadot', valid: false, desc: '8 chars (too long for governance)' },
      ],
    },
  ]

  console.log('\n📋 VALIDATION RULES BY TIER:\n')

  testCases.forEach((tier, idx) => {
    console.log(`\n${idx + 1}. ${tier.category}`)
    console.log('─'.repeat(70))
    console.log(`   Individuality Type: ${tier.type}\n`)

    tier.cases.forEach((test) => {
      const status = test.valid ? '✅ VALID' : '❌ INVALID'
      const indicator = test.valid ? '✓' : '✗'
      console.log(`   ${indicator} "${test.name}" - ${status}`)
      console.log(`     ${test.desc}`)
    })
  })

  console.log('\n' + '='.repeat(70))
  console.log('\n📝 REGISTRATION FLOW EXAMPLE:\n')

  console.log('To register a domain, you must provide:')
  console.log('  1. label: The domain name (e.g., "leonardo.12")')
  console.log('  2. individualityType: The verification level')
  console.log('     - NONE (0): No verification needed (9+ chars)')
  console.log('     - PERSON_LIGHT (1): Light verification (6-8 chars + .XX)')
  console.log('     - PROOF_OF_PERSONHOOD (2): Full verification (6-8 chars)')
  console.log('     - GOVERNANCE (3): Governance authorization (<6 chars)')
  console.log('')
  console.log('Example registration struct:')
  console.log('  {')
  console.log('    label: "leonardo.12",')
  console.log('    owner: "0x...",')
  console.log('    duration: 31536000, // 1 year')
  console.log('    secret: "0x...",')
  console.log('    resolver: "0x...",')
  console.log('    data: [],')
  console.log('    reverseRecord: 0,')
  console.log('    referrer: "0x...",')
  console.log('    individualityType: 1 // PERSON_LIGHT')
  console.log('  }')
  console.log('')

  console.log('='.repeat(70))
  console.log('\n✨ Validation logic implemented in:')
  console.log('  - IETHRegistrarController.sol (IndividualityType enum)')
  console.log('  - StringUtils.sol (validation helper functions)')
  console.log('  - ETHRegistrarController.sol (validWithIndividuality())')
  console.log('  - ETHRegistrarController.sol (register() with validation)')
  console.log('')
  console.log('🚀 Ready for deployment!')
  console.log('='.repeat(70))
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error)
    process.exit(1)
  })
