// Single source of truth for which language codes the plugin accepts,
// mirrored from lib/babel_reunited/locales.rb. A backend spec asserts the
// two lists stay in sync — update both together.
export const SUPPORTED_LOCALES = [
  "af",
  "am",
  "ar",
  "az",
  "be",
  "bg",
  "bn",
  "bs",
  "ca",
  "ceb",
  "ckb",
  "cs",
  "cy",
  "da",
  "de",
  "de-at",
  "de-ch",
  "el",
  "en",
  "en-au",
  "en-ca",
  "en-gb",
  "en-us",
  "eo",
  "es",
  "es-ar",
  "es-mx",
  "et",
  "eu",
  "fa",
  "fi",
  "fil",
  "fj",
  "fo",
  "fr",
  "fr-be",
  "fr-ca",
  "fr-ch",
  "fy",
  "ga",
  "gd",
  "gl",
  "gu",
  "ha",
  "haw",
  "he",
  "hi",
  "hr",
  "ht",
  "hu",
  "hy",
  "id",
  "ig",
  "is",
  "it",
  "it-ch",
  "ja",
  "jv",
  "ka",
  "kk",
  "km",
  "kn",
  "ko",
  "ku",
  "ky",
  "la",
  "lb",
  "lo",
  "lt",
  "lv",
  "mg",
  "mi",
  "mk",
  "ml",
  "mn",
  "mr",
  "ms",
  "mt",
  "my",
  "ne",
  "nl",
  "nl-be",
  "no",
  "pa",
  "pl",
  "ps",
  "pt",
  "pt-br",
  "pt-pt",
  "ro",
  "ru",
  "rw",
  "sd",
  "si",
  "sk",
  "sl",
  "sm",
  "sn",
  "so",
  "sq",
  "sr",
  "st",
  "su",
  "sv",
  "sw",
  "ta",
  "te",
  "tg",
  "th",
  "tk",
  "to",
  "tr",
  "tt",
  "ug",
  "uk",
  "ur",
  "uz",
  "vi",
  "xh",
  "yi",
  "yo",
  "yue",
  "zh-cn",
  "zh-hk",
  "zh-tw",
  "zu",
];

// Variants distinguished by place rather than by script. They stay valid
// server-side so pre-existing records and preferences keep working, but they
// are not offered: the translation is the same text at N times the price and
// fragments the cache. A different script is a real difference, which is why
// zh-cn and zh-tw survive (shown as Simplified/Traditional, not by country).
const PLACE_VARIANTS = new Set([
  "de-at",
  "de-ch",
  "en-au",
  "en-ca",
  "en-gb",
  "en-us",
  "es-ar",
  "es-mx",
  "fr-be",
  "fr-ca",
  "fr-ch",
  "it-ch",
  "nl-be",
  "pt-br",
  "pt-pt",
  "zh-hk",
]);

export const SELECTABLE_LOCALES = SUPPORTED_LOCALES.filter(
  (code) => !PLACE_VARIANTS.has(code)
);

// Mirrors BabelReunited.same_language? — a backend spec asserts the two agree.
// Regional variants translate to the same text, so a reader whose legacy
// preference is pt-br must not be offered (and charged for) a translation of a
// post already written in pt. Chinese variants are distinct scripts and never
// collapse.
export function sameLanguage(a, b) {
  if (!a || !b) {
    return false;
  }

  a = a.toLowerCase();
  b = b.toLowerCase();
  if (a === b) {
    return true;
  }

  const primaryA = a.split("-")[0];
  const primaryB = b.split("-")[0];
  if (primaryA === "zh" || primaryB === "zh") {
    return false;
  }

  return primaryA === primaryB;
}
