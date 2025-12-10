import { viem } from 'hardhat'

async function main() {
  console.log('Testing domain name validation...\n')

  // Deploy ETHRegistrarController (we only need to test the valid() function)
  // For testing, we'll just deploy a minimal setup

  const testCases = [
    // Valid cases
    { name: 'leonardo.12', expected: true, description: 'Valid: 8 chars + dot + 2 digits' },
    { name: 'abcdef.00', expected: true, description: 'Valid: exactly 6 chars + dot + 2 digits' },
    { name: 'polkadot.99', expected: true, description: 'Valid: 8 chars + dot + 2 digits' },
    { name: 'crypto.42', expected: true, description: 'Valid: 6 chars + dot + 2 digits' },

    // Invalid cases
    { name: 'abc.12', expected: false, description: 'Invalid: only 3 chars before dot (need 6+)' },
    { name: 'abcde.12', expected: false, description: 'Invalid: only 5 chars before dot (need 6+)' },
    { name: 'leonardo.1', expected: false, description: 'Invalid: only 1 digit after dot (need 2)' },
    { name: 'leonardo.123', expected: false, description: 'Invalid: 3 digits after dot (need exactly 2)' },
    { name: 'leonardo', expected: false, description: 'Invalid: no dot' },
    { name: 'leonardo.ab', expected: false, description: 'Invalid: letters after dot instead of digits' },
    { name: 'leo.12.34', expected: false, description: 'Invalid: multiple dots' },
    { name: '.12', expected: false, description: 'Invalid: no chars before dot' },
  ]

  console.log('Test cases to validate:\n')
  testCases.forEach((tc, idx) => {
    console.log(`${idx + 1}. "${tc.name}" - ${tc.description}`)
    console.log(`   Expected: ${tc.expected ? 'VALID ✓' : 'INVALID ✗'}`)
  })

  console.log('\n' + '='.repeat(60))
  console.log('To run actual contract tests, deploy the contracts first.')
  console.log('The validation logic has been implemented in:')
  console.log('  - StringUtils.isValidDotnsFormat()')
  console.log('  - ETHRegistrarController.valid()')
  console.log('='.repeat(60))
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error)
    process.exit(1)
  })
