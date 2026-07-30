import I18n from "discourse-i18n";

// Language display names come from the browser's Intl.DisplayNames in the
// viewer's interface locale — no hand-maintained i18n key per language.
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

export function languageDisplayName(code) {
  if (!code) {
    return code;
  }

  const locale = (I18n.currentLocale() || "en").replace(/_/g, "-");

  try {
    return displayNamesFor(locale)?.of(code) || code;
  } catch {
    return code;
  }
}
