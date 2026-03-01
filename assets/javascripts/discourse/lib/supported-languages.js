export function getSupportedLanguages(siteSettings) {
  const setting = siteSettings.babel_reunited_auto_translate_languages;
  if (!setting) {
    return [];
  }
  return setting
    .split(",")
    .map((s) => s.trim())
    .filter(Boolean);
}
