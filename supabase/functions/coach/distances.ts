// The race distances create_plan may name (#184): the keys of plan/generator.ts's DISTANCES,
// plus "custom" with distance_m. The same labels as the app's IntakeAnswers.Distance.
//
// A copy rather than an import so the coach bundle doesn't pull in the plan generator;
// distances_test.ts holds the two lists equal, so adding a distance to the table and
// forgetting it here fails CI instead of producing a card the plan engine refuses.
export const RACE_DISTANCES = ["1mi", "5k", "10k", "15k", "10mi", "half", "marathon", "custom"];
