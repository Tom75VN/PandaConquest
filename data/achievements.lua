PandaConquest = PandaConquest or {}

-- Achievement catalog: the single source of identifiers, campaigns and targets
-- (decision 0046; what it contains and when: decision 0045). Data only: tables, strings, integers, true/false and line
-- comments. The companion repository's admin tool reads it as data, never runs
-- it, and writes the Worker's D1 migration from it.
-- Entry: id, campaignId, progressType (boolean, counter, tier), target,
-- reliability (RELIABLE, RECONSTRUCTED, BEST_EFFORT, MANUAL); addon-only:
-- category, detection, titleKey, descriptionKey. Identifiers are final.
PandaConquest.AchievementCatalog = {
  schema = 1,
  achievements = {
  },
}
