import I18n from "discourse-i18n";

// Language names come from the browser's Intl.DisplayNames — no
// hand-maintained i18n key per language.
//
// The endonym (a language's name in itself) is what a reader looking for
// their own language recognizes, so it leads in the UI. The name in the
// viewer's interface locale stays available as a secondary label, which is
// what makes an unfamiliar script identifiable to an admin.
// What makes these two worth offering separately is the script, not the
// place, so they are displayed by their script subtag: "Simplified Chinese"
// rather than "Chinese (China)". The stored codes stay as they are — they
// identify existing translations, preferences and settings.
const DISPLAY_CODE = {
  "zh-cn": "zh-Hans",
  "zh-tw": "zh-Hant",
};

const cache = new Map();

function buildDisplayNames(locale) {
  try {
    return new Intl.DisplayNames([locale, "en"], { type: "language" });
  } catch {
    return null;
  }
}

function displayNamesFor(locale) {
  if (!cache.has(locale)) {
    cache.set(locale, buildDisplayNames(locale));
  }
  return cache.get(locale);
}

function nameIn(locale, code) {
  try {
    return displayNamesFor(locale)?.of(code) || null;
  } catch {
    return null;
  }
}

// CLDR gives endonyms in each language's own casing convention ("español",
// "русский"). Language switchers conventionally capitalize; this is a no-op
// for scripts without case.
function capitalize(name) {
  return name ? name.charAt(0).toUpperCase() + name.slice(1) : name;
}

export function languageDisplayName(code) {
  if (!code) {
    return code;
  }

  const locale = (I18n.currentLocale() || "en").replace(/_/g, "-");
  const displayCode = DISPLAY_CODE[code] || code;
  return nameIn(locale, displayCode) || code;
}

export function languageEndonym(code) {
  if (!code) {
    return code;
  }

  const displayCode = DISPLAY_CODE[code] || code;
  return capitalize(nameIn(displayCode, displayCode)) || code;
}
