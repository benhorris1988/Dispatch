/// Definitions for the portfolio and loan figures (REP-04: every number says
/// how it is measured). The server sends its own wording for the four portfolio
/// figures in `portfolios.php overview.definitions`; these are the fallbacks
/// and the client-only ones.
class PfMetrics {
  PfMetrics._();

  static const String loans =
      'A loan lends a person to another team for a dated period at a share of their time. '
      'For those dates the share of their capacity belongs to the borrowing team and they can be planned on its work; '
      'the rest stays with their own team. Loans do not change anyone\'s hours. '
      'Ending a loan early keeps it as history; a loan that has not started is cancelled outright. '
      'Only a business reason is recorded — never personal detail.';

  static const String headcount =
      'Home members of the team. The pool is the headcount plus anyone loaned in during the window; '
      'loaned in and loaned out count people lent into or out of the team within the window.';

  static String load({num targetMin = 80, num targetMax = 90}) =>
      'Committed assignment hours ÷ available hours over the next four weeks, each person weighted by the share of their time '
      'that belongs to the team (loans). Target band $targetMin–$targetMax%.';

  static const String singleSkillDeps =
      'Skills the team\'s committed work needs in the planned window that exactly one person in the team '
      '(including anyone loaned in) holds at the required level. The portfolio figure can be lower than any team\'s, '
      'because another team in it may cover the skill.';

  static const String stabilityIndex =
      '1 − moved assignment-days in the last four weeks ÷ the team\'s own people\'s committed assignment-days over those weeks '
      'and the planned window (STAB-08).';

  static const String openProposals = 'Pending changes in the open proposal that name one of the team\'s own people.';
}
