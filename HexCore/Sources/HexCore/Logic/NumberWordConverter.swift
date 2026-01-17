import Foundation

/// Converts spoken cardinal number words to numeric digits.
/// Example: "twenty five" → "25", "one thousand three hundred thirty six" → "1336"
/// Preserves word boundaries (someone, threesome).
public enum NumberWordConverter {
	// MARK: - Number Word Mappings

	private static let ones: [String: Int] = [
		"zero": 0, "one": 1, "two": 2, "three": 3, "four": 4,
		"five": 5, "six": 6, "seven": 7, "eight": 8, "nine": 9,
		"ten": 10, "eleven": 11, "twelve": 12, "thirteen": 13,
		"fourteen": 14, "fifteen": 15, "sixteen": 16, "seventeen": 17,
		"eighteen": 18, "nineteen": 19
	]

	private static let tens: [String: Int] = [
		"twenty": 20, "thirty": 30, "forty": 40, "fifty": 50,
		"sixty": 60, "seventy": 70, "eighty": 80, "ninety": 90
	]

	private static let scales: [String: Int] = [
		"hundred": 100,
		"thousand": 1000,
		"million": 1_000_000,
		"billion": 1_000_000_000,
		"trillion": 1_000_000_000_000
	]

	/// Words that are part of number expressions but not numbers themselves
	private static let connectors: Set<String> = ["and"]

	// MARK: - Public API

	/// Converts number words to digits in the given text.
	/// - Parameter text: The input text containing number words
	/// - Returns: Text with number words converted to digits
	public static func apply(_ text: String) -> String {
		guard !text.isEmpty else { return text }

		let tokens = tokenize(text)
		var result: [String] = []
		var i = 0

		while i < tokens.count {
			let token = tokens[i]

			// Check if this token starts a number sequence
			if isNumberWord(token.lowercased()) {
				let (numberTokens, value, hasDecimal, decimalValue) = parseNumberSequence(tokens: tokens, startIndex: i)

				if numberTokens > 0 {
					// Format the number
					if hasDecimal {
						result.append(formatDecimal(value, decimalValue))
					} else {
						result.append(String(value))
					}
					i += numberTokens
					continue
				}
			}

			// Not a number word, keep as-is
			result.append(token)
			i += 1
		}

		return result.joined()
	}

	// MARK: - Tokenization

	/// Tokenizes text into words, whitespace, and punctuation, preserving everything.
	private static func tokenize(_ text: String) -> [String] {
		var tokens: [String] = []
		var currentToken = ""
		var currentType: TokenType?

		for char in text {
			let charType = tokenType(for: char)

			if charType == currentType {
				currentToken.append(char)
			} else {
				if !currentToken.isEmpty {
					tokens.append(currentToken)
				}
				currentToken = String(char)
				currentType = charType
			}
		}

		if !currentToken.isEmpty {
			tokens.append(currentToken)
		}

		return tokens
	}

	private enum TokenType {
		case word
		case whitespace
		case punctuation
	}

	private static func tokenType(for char: Character) -> TokenType {
		if char.isWhitespace {
			return .whitespace
		} else if char.isLetter || char == "-" || char == "'" {
			return .word
		} else {
			return .punctuation
		}
	}

	// MARK: - Number Parsing

	/// Checks if a word (lowercased) is a number word.
	private static func isNumberWord(_ word: String) -> Bool {
		// Handle hyphenated numbers like "twenty-five"
		let parts = word.split(separator: "-").map { String($0) }
		if parts.count == 2 {
			return isNumberWord(parts[0]) && isNumberWord(parts[1])
		}

		return ones[word] != nil || tens[word] != nil || scales[word] != nil
	}

	/// Parses a sequence of number words starting at the given index.
	/// Returns: (tokensConsumed, integerValue, hasDecimal, decimalString)
	private static func parseNumberSequence(tokens: [String], startIndex: Int) -> (Int, Int, Bool, String) {
		var tokensConsumed = 0
		var currentValue = 0
		var total = 0
		var lastWasNumber = false
		var i = startIndex

		// Track decimal part
		var hasDecimal = false
		var decimalString = ""
		var inDecimal = false

		while i < tokens.count {
			let token = tokens[i]
			let lower = token.lowercased()

			// Skip whitespace between number words
			if token.allSatisfy({ $0.isWhitespace }) {
				if lastWasNumber || inDecimal {
					// Peek ahead to see if next non-whitespace continues the number sequence
					var nextIndex = i + 1
					while nextIndex < tokens.count && tokens[nextIndex].allSatisfy({ $0.isWhitespace }) {
						nextIndex += 1
					}
					if nextIndex < tokens.count {
						let nextLower = tokens[nextIndex].lowercased()
						let canContinue: Bool
						if inDecimal {
							canContinue = ones[nextLower] != nil
						} else {
							canContinue = isNumberWord(nextLower) || connectors.contains(nextLower) || nextLower == "point"
						}
						if canContinue {
							tokensConsumed += 1
							i += 1
							continue
						}
					}
				}
				break
			}

			// Handle "point" for decimals
			if lower == "point" && lastWasNumber && !inDecimal {
				inDecimal = true
				hasDecimal = true
				tokensConsumed += 1
				i += 1
				lastWasNumber = false
				continue
			}

			// Handle decimal digits (after "point")
			if inDecimal {
				if let digitValue = ones[lower], digitValue <= 9 {
					decimalString.append(String(digitValue))
					tokensConsumed += 1
					i += 1
					lastWasNumber = true
					continue
				} else {
					// End of decimal
					break
				}
			}

			// Handle connectors like "and"
			if connectors.contains(lower) && lastWasNumber {
				tokensConsumed += 1
				i += 1
				continue
			}

			// Handle hyphenated numbers like "twenty-five"
			let parts = lower.split(separator: "-").map { String($0) }
			if parts.count == 2, let tensVal = tens[parts[0]], let onesVal = ones[parts[1]] {
				currentValue += tensVal + onesVal
				tokensConsumed += 1
				i += 1
				lastWasNumber = true
				continue
			}

			// Handle ones (0-19)
			if let value = ones[lower] {
				currentValue += value
				tokensConsumed += 1
				i += 1
				lastWasNumber = true
				continue
			}

			// Handle tens (20, 30, ... 90)
			if let value = tens[lower] {
				currentValue += value
				tokensConsumed += 1
				i += 1
				lastWasNumber = true
				continue
			}

			// Handle scales (hundred, thousand, million, billion)
			if let scale = scales[lower] {
				if scale == 100 {
					// "hundred" multiplies current value
					currentValue = (currentValue == 0 ? 1 : currentValue) * 100
				} else {
					// thousand/million/billion: multiply current group and add to total
					let groupValue = (currentValue == 0 ? 1 : currentValue) * scale
					total += groupValue
					currentValue = 0
				}
				tokensConsumed += 1
				i += 1
				lastWasNumber = true
				continue
			}

			// Not a number word
			break
		}

		total += currentValue

		// Only return consumed tokens if we actually parsed a number
		if tokensConsumed > 0 && (hasDecimal || total > 0 || (tokensConsumed == 1 && tokens[startIndex].lowercased() == "zero")) {
			return (tokensConsumed, total, hasDecimal, decimalString)
		}

		return (0, 0, false, "")
	}

	/// Formats a decimal number.
	private static func formatDecimal(_ intPart: Int, _ decimalPart: String) -> String {
		if decimalPart.isEmpty {
			return "\(intPart)."
		}
		return "\(intPart).\(decimalPart)"
	}
}
