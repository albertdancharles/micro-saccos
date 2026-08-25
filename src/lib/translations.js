// Swahili translations. Keys are the English source strings; values are Swahili.
// Template placeholders use {name} syntax — callers do .replace('{name}', value).
// Falls back to the key itself (English) for any missing entry.

const sw = {
  // Common
  'Loading…': 'Inapakia…',
  'Cancel': 'Ghairi',
  'Submitting…': 'Inatuma…',
  'Saving…': 'Inahifadhi…',
  'Working…': 'Inafanya kazi…',
  'Reason': 'Sababu',
  'Email': 'Barua pepe',
  'Phone': 'Simu',
  'Amount (TSh)': 'Kiasi (TSh)',
  'by': 'na',
  'due': 'inastahili',
  'unknown': 'haijulikani',
  'system': 'mfumo',
  'admin': 'msimamizi',
  'member': 'mwanachama',
  'total': 'jumla',

  // Navigation
  'Micro-SACCOS · Admin': 'Micro-SACCOS · Msimamizi',
  'Micro-SACCOS · Umoja Group': 'Micro-SACCOS · Kikundi cha Umoja',
  'Micro-SACCOS': 'Micro-SACCOS',
  'My view': 'Muhtasari wangu',
  'Audit': 'Ukaguzi',
  'Profile': 'Wasifu',
  'Sign out': 'Toka',
  '← Back': '← Rudi',
  '← Admin': '← Msimamizi',

  // Login
  'Welcome back': 'Karibu tena',
  'Password': 'Nywila',
  'Forgot?': 'Umesahau?',
  'Sign in': 'Ingia',
  'Signing in…': 'Inaingia…',
  'Sign in failed. Check your email and password.': 'Kuingia kulishindwa. Angalia barua pepe na nywila yako.',
  'Enter your email first, then tap "Forgot password?".': 'Weka barua pepe yako kwanza, kisha bonyeza "Umesahau nywila?".',
  'If that email exists, a reset link is on its way.': 'Kama barua pepe hiyo ipo, kiungo cha kuweka upya kinaendelea.',
  'Could not send the reset email.': 'Haikuweza kutuma barua pepe ya kuweka upya.',
  'A small group, big trust. Your savings are visible only to you and the admin team.': 'Kikundi kidogo, imani kubwa. Akiba yako inaonekana kwako tu na timu ya wasimamizi.',
  'A small group, big trust. Every member can see the group’s savings and loans.': 'Kikundi kidogo, imani kubwa. Kila mwanachama anaweza kuona akiba na mikopo ya kikundi.',

  // Update password
  'Set a new password': 'Weka nywila mpya',
  "Choose something you'll remember.": 'Chagua kitu utakachokumbuka.',
  'Checking your link…': 'Inakagua kiungo chako…',
  'This reset link is invalid or has expired.': 'Kiungo hiki cha kuweka upya si sahihi au kimeisha muda wake.',
  'Back to sign in': 'Rudi kuingia',
  'New password': 'Nywila mpya',
  'Confirm password': 'Thibitisha nywila',
  'At least 8 characters': 'Angalau herufi 8',
  'Re-enter password': 'Weka tena nywila',
  'Use at least 8 characters.': 'Tumia angalau herufi 8.',
  'Passwords do not match.': 'Nywila hazilingani.',
  'Save password': 'Hifadhi nywila',
  'Password changed.': 'Nywila imebadilishwa.',
  'Could not change password.': 'Haikuweza kubadilisha nywila.',
  'Could not update your password.': 'Haikuweza kusasisha nywila yako.',

  // Sign up / Google / onboarding (v3)
  'or': 'au',
  'New here?': 'Mgeni hapa?',
  'Create an account': 'Fungua akaunti',
  'Create your account': 'Fungua akaunti yako',
  'Create account': 'Fungua akaunti',
  'Already have an account?': 'Una akaunti tayari?',
  'Continue with Google': 'Endelea na Google',
  'Sign up with Google': 'Jisajili na Google',
  'Redirecting…': 'Inaelekeza…',
  'Could not start Google sign-in.': 'Haikuweza kuanzisha kuingia kwa Google.',
  'or with email': 'au kwa barua pepe',
  'Enter your email.': 'Weka barua pepe yako.',
  'Password must be at least 8 characters.': 'Nywila lazima iwe na angalau herufi 8.',
  'Please fill in all required fields.': 'Tafadhali jaza sehemu zote zinazohitajika.',
  'Could not create your account.': 'Haikuweza kufungua akaunti yako.',
  'Almost there — check your email to confirm your address, then sign in. An admin will review your membership.':
    'Karibu umemaliza — angalia barua pepe yako kuthibitisha anwani yako, kisha ingia. Msimamizi atakagua uanachama wako.',

  // Profile fields
  'Additional phone (optional)': 'Simu ya ziada (hiari)',
  'Residence': 'Makazi',
  'e.g. Mbezi Beach, Dar es Salaam': 'mf. Mbezi Beach, Dar es Salaam',
  'National ID (NIDA)': 'Kitambulisho cha Taifa (NIDA)',
  'National ID (NIDA) (optional)': 'Kitambulisho cha Taifa (NIDA) (hiari)',
  'Next of kin — name': 'Ndugu wa karibu — jina',
  'Next of kin — name (optional)': 'Ndugu wa karibu — jina (hiari)',
  'Next of kin — phone': 'Ndugu wa karibu — simu',
  'Next of kin — phone (optional)': 'Ndugu wa karibu — simu (hiari)',
  'Next of kin': 'Ndugu wa karibu',
  'Additional phone': 'Simu ya ziada',

  // Complete profile
  'Complete your profile': 'Kamilisha wasifu wako',
  'A few details before an admin reviews your membership.':
    'Maelezo machache kabla msimamizi hajakagua uanachama wako.',
  'Signed in as': 'Umeingia kama',
  'Save and continue': 'Hifadhi na uendelee',
  'Could not save your details.': 'Haikuweza kuhifadhi maelezo yako.',

  // Pending approval
  'Awaiting approval': 'Inasubiri idhini',
  'Thanks, {name}! Your details are in. An admin will review and activate your account soon.':
    'Asante, {name}! Maelezo yako yamepokelewa. Msimamizi atakagua na kuwasha akaunti yako hivi karibuni.',
  'there': 'wewe',
  'Check status': 'Angalia hali',
  'Checking…': 'Inakagua…',

  // Pending registrations (admin)
  'Pending registrations ({n})': 'Usajili unaosubiri ({n})',
  'Applied {date}': 'Aliomba {date}',
  'pending': 'inasubiri',
  'Approve member': 'Idhinisha mwanachama',
  'Reject and permanently remove this applicant?':
    'Kataa na uondoe kabisa mwombaji huyu?',
  'Could not approve the member.': 'Haikuweza kuidhinisha mwanachama.',
  'Could not reject the applicant.': 'Haikuweza kukataa mwombaji.',

  // Dashboard
  '+ Add member': '+ Ongeza mwanachama',
  'Viewing as admin': 'Inaangalia kama msimamizi',
  '+ Log a transaction': '+ Ingiza muamala',
  'Loading dashboard…': 'Inapakia dashibodi…',
  "Read-only view. Submitting payments, requesting loans, and editing on this member's behalf are disabled. Use the savings edit / approvals queue on the admin dashboard to act.":
    'Mtazamo wa kusoma tu. Kutuma malipo, kuomba mikopo, na kuhariri kwa niaba ya mwanachama huu kumezimwa. Tumia foleni ya hariri/idhini kwenye dashibodi ya msimamizi kuchukua hatua.',

  // Profile
  'Account': 'Akaunti',
  'Name': 'Jina',
  'Role': 'Jukumu',
  'Phone number': 'Nambari ya simu',
  'Phone number updated.': 'Nambari ya simu imesasishwa.',
  'Could not update phone.': 'Haikuweza kusasisha nambari ya simu.',
  'Save phone': 'Hifadhi simu',
  'Confirm': 'Thibitisha',
  'Change password': 'Badilisha nywila',
  'My contributions': 'Michango yangu',
  'Total savings': 'Jumla ya akiba',
  'Includes your savings deposits, paid monthly fees, and any admin-approved adjustments. Your loan ceiling is {n}× this amount (capped at {p}% of the group pool).':
    'Inajumuisha amana za akiba, ada za kila mwezi zilizolipwa, na marekebisho yoyote ya msimamizi. Kiwango chako cha mkopo ni mara {n} ya kiasi hiki (kiwango cha {p}% ya hazina ya kikundi).',
  'Statement': 'Taarifa',
  'Download a CSV with your savings, fees, loans, and full submission history.': 'Pakua CSV yenye akiba yako, ada, mikopo, na historia kamili ya uwasilishaji.',
  'Download statement (CSV)': 'Pakua taarifa (CSV)',
  'Preparing…': 'Inaandaa…',
  'Could not generate the statement.': 'Haikuweza kuunda taarifa.',
  'Could not load contributions.': 'Haikuweza kupakia michango.',
  'Back to dashboard': 'Rudi dashibodi',

  // Audit log
  'Audit log': 'Kumbukumbu ya ukaguzi',
  'Could not load the audit log.': 'Haikuweza kupakia kumbukumbu ya ukaguzi.',
  'No audit entries yet.': 'Hakuna maingizo ya ukaguzi bado.',
  'Request cancelled': 'Ombi lilighairiwa',
  'Approved payment': 'Malipo yaliyoidhinishwa',
  'Partially approved payment': 'Malipo yaliyoidhinishwa kwa sehemu',
  'Rejected payment': 'Malipo yaliyokataliwa',
  'Approved loan': 'Mkopo ulioidhinishwa',
  'Partially approved loan': 'Mkopo ulioidhinishwa kwa sehemu',
  'Rejected loan': 'Mkopo uliokataliwa',
  'Generated monthly fees': 'Ada za kila mwezi ziliundwa',
  'Updated phone': 'Simu ilisasishwa',
  'Added member': 'Mwanachama aliongezwa',
  'Requested member deletion': 'Ufutaji wa mwanachama uliombwa',
  'Partially approved deletion': 'Ufutaji ulioidhinishwa kwa sehemu',
  'Deleted member': 'Mwanachama alifutwa',
  'Cancelled deletion': 'Ufutaji ulighairiwa',
  'Requested savings edit': 'Marekebisho ya akiba yaliombwa',
  'Partially approved savings edit': 'Marekebisho ya akiba kwa sehemu',
  'Applied savings edit': 'Marekebisho ya akiba yalitekelezwa',
  'Cancelled savings edit': 'Marekebisho ya akiba yalighairiwa',
  'Requested pool edit': 'Marekebisho ya hazina yaliombwa',
  'Partially approved pool edit': 'Marekebisho ya hazina kwa sehemu',
  'Applied pool edit': 'Marekebisho ya hazina yalitekelezwa',
  'Cancelled pool edit': 'Marekebisho ya hazina yalighairiwa',
  'Requested role change': 'Mabadiliko ya jukumu yaliombwa',
  'Partially approved role change': 'Mabadiliko ya jukumu kwa sehemu',
  'Applied role change': 'Mabadiliko ya jukumu yalitekelezwa',

  // Audit actions from the admin mandate (034–037).
  'Recorded payment': 'Malipo yameingizwa',
  'Recorded monthly fees': 'Ada za mwezi zimeingizwa',
  'Filed loan': 'Mkopo umefunguliwa',
  'Opened withdrawal': 'Utoaji umefunguliwa',
  'Requested correction': 'Marekebisho yameombwa',
  'Partially approved correction': 'Marekebisho yameidhinishwa kwa sehemu',
  'Applied correction': 'Marekebisho yametekelezwa',
  'Cancelled correction': 'Marekebisho yameghairiwa',
  'Admin mandate applied': 'Mamlaka ya msimamizi yametekelezwa',
  'Guarantees removed': 'Dhamana zimeondolewa',
  'Cancelled role change': 'Mabadiliko ya jukumu yalighairiwa',

  // Admin summary cards
  'Total group assets': 'Jumla ya mali ya kikundi',
  'in the pool': 'katika hazina',
  'out on loans': 'kwenye mikopo',
  'Group pool': 'Hazina ya kikundi',
  'Fees this month': 'Ada mwezi huu',
  'Active loans': 'Mikopo inayoendelea',
  'Pending reviews': 'Mapitio yanayosubiri',

  // Add member modal
  'Add a member': 'Ongeza mwanachama',
  'Full name': 'Jina kamili',
  'Email (login)': 'Barua pepe (kuingia)',
  'A real email enables self-service password reset; otherwise you reset it for them.':
    'Barua pepe halisi inaruhusu mwanachama kuweka upya nywila mwenyewe; vinginevyo unaweka upya kwa niaba yake.',
  'Create member': 'Unda mwanachama',
  'Creating…': 'Inaunda…',
  'Could not create the member.': 'Haikuweza kuunda mwanachama.',
  'Member created. Share these temp credentials — they change the password on first login.':
    'Mwanachama ameundwa. Shiriki vitambulisho hivi vya muda — wanabadilisha nywila wakati wa kuingia kwa mara ya kwanza.',
  'Temp password': 'Nywila ya muda',
  'Done': 'Imekamilika',
  'Name, email, and phone are all required.': 'Jina, barua pepe, na simu zinahitajika zote.',

  // Member grid
  'Members': 'Wanachama',
  'Member': 'Mwanachama',
  '{n} total': 'jumla {n}',
  '{n} overdue': '{n} wamechelewa',
  'Monthly fee': 'Ada ya kila mwezi',
  'Loan interest': 'Riba ya mkopo',
  'Overall': 'Jumla',
  'Actions': 'Vitendo',
  'Actions for {name}': 'Vitendo kwa {name}',
  'View': 'Angalia',
  'Edit savings': 'Hariri akiba',
  'Revoke admin': 'Ondoa usimamizi',
  'Make admin': 'Fanya msimamizi',
  'Delete': 'Futa',

  // Approvals queue
  'Approvals': 'Idhini',
  'Payments': 'Malipo',
  'Loans': 'Mikopo',
  'All caught up — no payments awaiting review.': 'Hakuna malipo yanayosubiri mapitio.',
  'No loan requests awaiting review.': 'Hakuna maombi ya mikopo yanayosubiri mapitio.',

  // Loan queue item
  'First-time borrower': 'Mkopaji wa kwanza',
  'Requested {date}': 'Iliombwa {date}',
  "You can't approve your own loan.": 'Huwezi kuidhinisha mkopo wako mwenyewe.',
  "You've already approved ({a}/{r}). Awaiting another admin.": 'Umeshaidhinisha ({a}/{r}). Inasubiri msimamizi mwingine.',
  'Approved by {names} ({a}/{r}).': 'Imeidhinishwa na {names} ({a}/{r}).',
  'Member savings': 'Akiba ya mwanachama',
  '5× savings': 'Mara 5 ya akiba',
  '25% of pool': '25% ya hazina',
  'Max eligible': 'Kiwango cha juu',
  'Requested': 'Kilichoombwa',
  'Exceeds the {cap} cap; the database will reject the approval.': 'Inazidi kiwango cha {cap}; mfumo utakataa idhini.',
  'Reason for rejection': 'Sababu ya kukataa',
  'Confirm reject': 'Thibitisha kukataa',
  'Rejecting…': 'Inakataa…',
  'Upload the M-Pesa disbursement screenshot first.': 'Pakia picha ya skrini ya malipo ya M-Pesa kwanza.',
  'Could not approve the loan.': 'Haikuweza kuidhinisha mkopo.',
  'Could not reject the loan.': 'Haikuweza kukataa mkopo.',
  'Add a short reason for the rejection.': 'Ongeza sababu fupi ya kukataa.',
  'Confirming…': 'Inathibitisha…',
  'Approving…': 'Inaidhinisha…',
  'Confirm & disburse ({a}/{r})': 'Thibitisha & toa ({a}/{r})',
  'Approve & disburse ({a}/{r})': 'Idhinisha & toa ({a}/{r})',
  'Submit approval ({a}/{r})': 'Tuma idhini ({a}/{r})',
  'Disbursement proof (from first approver)': 'Uthibitisho wa utoaji (kutoka kwa muidhinishaji wa kwanza)',
  'Disbursement proof': 'Uthibitisho wa utoaji',
  'View proof': 'Angalia uthibitisho',
  'Approve': 'Idhinisha',
  'Reject': 'Kataa',

  // Payment queue item
  'Savings deposit': 'Amana ya akiba',
  'Loan repayment': 'Malipo ya mkopo',
  "You can't approve your own submission.": 'Huwezi kuidhinisha uwasilishaji wako mwenyewe.',
  'Claimed': 'Ilidaiwa',
  'incl. {p} penalty': 'ikiwa na faini ya {p}',
  'for {month}': 'kwa {month}',
  'Amount received (TSh)': 'Kiasi kilichopokelewa (TSh)',
  '(locked by first approver)': '(imefungwa na muidhinishaji wa kwanza)',
  'Enter the amount received.': 'Weka kiasi kilichopokelewa.',
  'Approve ({a}/{r})': 'Idhinisha ({a}/{r})',
  'View screenshot': 'Angalia picha ya skrini',

  // Deletion queue
  'Pending member deletions ({n})': 'Ufutaji wa wanachama unaoendelea ({n})',
  'Delete {name}': 'Futa {name}',
  'Requested by {name} · {date}': 'Iliombwa na {name} · {date}',
  'Total savings (will be lost)': 'Jumla ya akiba (itapotea)',
  'Reason:': 'Sababu:',
  "You can't approve your own deletion.": 'Huwezi kuidhinisha ufutaji wako mwenyewe.',
  'Could not approve the deletion.': 'Haikuweza kuidhinisha ufutaji.',
  'Could not cancel.': 'Haikuweza kughairi.',
  'Cancel this deletion request?': 'Ghairi ombi hili la ufutaji?',
  'Approve & delete ({a}/{r})': 'Idhinisha & futa ({a}/{r})',
  'Cancel request': 'Ghairi ombi',

  // Request deletion modal
  'Request member deletion': 'Omba ufutaji wa mwanachama',
  'This is irreversible.': 'Hii haiwezi kubatilishwa.',
  'Once two admins authorize, {name} and every record below will be permanently deleted. The group pool decreases by their approved savings.':
    'Wasimamizi wawili wakiidhinisha, {name} na kumbukumbu zote zitafutwa kabisa. Hazina ya kikundi itapungua kwa akiba yake iliyoidhinishwa.',
  'Includes deposits, paid monthly fees, and admin adjustments. All erased.':
    'Inajumuisha amana, ada za kila mwezi zilizolipwa, na marekebisho ya msimamizi. Yote yatafutwa.',
  'This member has an active loan. Deleting them will wipe the loan and its repayment history — the pool loses the outstanding principal.':
    'Mwanachama huyu ana mkopo unaoendelea. Kumfuta kutafuta mkopo na historia yake ya malipo — hazina itapoteza mtaji unaobaki.',
  'This member is an admin. The system blocks deleting the last remaining admin.':
    'Mwanachama huyu ni msimamizi. Mfumo unazuia kufuta msimamizi wa mwisho aliyebaki.',
  'e.g. member exited the group': 'mf. mwanachama alitoka kwa kikundi',
  'Type': 'Andika',
  'to confirm': 'kuthibitisha',
  'Add a short reason — every deletion is recorded in the audit log.':
    'Ongeza sababu fupi — kila ufutaji unakumbukwa katika kumbukumbu ya ukaguzi.',
  'Type {NAME} exactly to confirm.': 'Andika {NAME} hasa kuthibitisha.',
  'Request deletion': 'Omba ufutaji',
  'Could not open the deletion request.': 'Haikuweza kufungua ombi la ufutaji.',

  // Savings edit queue
  'Pending savings edits ({n})': 'Marekebisho ya akiba yanayosubiri ({n})',
  "Edit {name}'s savings": 'Hariri akiba ya {name}',
  "You opened this request — you can't vote on it. Awaiting other admins.":
    'Ulifungua ombi hili — huwezi kupiga kura juu yake. Inasubiri wasimamizi wengine.',
  "This edit targets your own savings — you can't approve it.":
    'Marekebisho haya yanalenga akiba yako mwenyewe — huwezi kuidhinisha.',
  'Current savings': 'Akiba ya sasa',
  'After edit': 'Baada ya marekebisho',
  'Could not approve the edit.': 'Haikuweza kuidhinisha marekebisho.',
  'Cancel this savings edit request?': 'Ghairi ombi hili la kuhariri akiba?',
  'Approve & apply ({a}/{r})': 'Idhinisha & tekeleza ({a}/{r})',

  // Request savings edit modal
  'Edit member savings': 'Hariri akiba ya mwanachama',
  'Increase': 'Ongeza',
  'Decrease': 'Punguza',
  'New savings would be {amount}.': 'Akiba mpya ingekuwa {amount}.',
  'e.g. correction of a missed deposit on 2026-04-15': 'mf. marekebisho ya amana iliyokosekana tarehe 2026-04-15',
  'Enter an amount greater than zero.': 'Weka kiasi zaidi ya sifuri.',
  'A reason is required for every savings edit.': 'Sababu inahitajika kwa kila marekebisho ya akiba.',
  'This would leave {name} with a negative balance ({amount}).':
    'Hii itamwacha {name} na salio hasi ({amount}).',
  "Two other admins must approve this edit before it applies. You can't approve your own request.":
    'Wasimamizi wengine wawili lazima waidhinishe marekebisho haya kabla hayajatekelezwa. Huwezi kuidhinisha ombi lako mwenyewe.',
  'Submit edit': 'Tuma marekebisho',
  'Could not open the savings edit request.': 'Haikuweza kufungua ombi la kuhariri akiba.',

  // Role change queue
  'Pending role changes ({n})': 'Mabadiliko ya jukumu yanayosubiri ({n})',
  'Promote {name}': 'Pandisha {name}',
  'Revoke admin from {name}': 'Ondoa usimamizi kutoka kwa {name}',
  'promote': 'pandisha',
  'revoke': 'ondoa',
  "This change targets you — you can't approve it.": 'Mabadiliko haya yanakulenga wewe — huwezi kuidhinisha.',
  'Could not approve the role change.': 'Haikuweza kuidhinisha mabadiliko ya jukumu.',
  'Cancel this role-change request?': 'Ghairi ombi hili la mabadiliko ya jukumu?',

  // Request role change modal
  'Promote to admin': 'Pandisha hadi msimamizi',
  'Revoke admin role': 'Ondoa jukumu la usimamizi',
  ' is currently ': ' sasa hivi ni ',
  'Becoming an admin lets them approve transactions and request edits.':
    'Kuwa msimamizi kunawaruhusu kuidhinisha miamala na kuomba marekebisho.',
  'Revoking admin removes their ability to approve and request edits.':
    'Kuondoa usimamizi huondoa uwezo wao wa kuidhinisha na kuomba marekebisho.',
  'e.g. trusted treasurer, served as group secretary': 'mf. mweka hazina anayeaminiwa, aliwahi kuwa katibu wa kikundi',
  'e.g. stepping down, no longer active in committee': 'mf. anashuka, hayupo tena katika kamati',
  "Two other admins must approve before the role flips. You can't approve your own request.":
    'Wasimamizi wengine wawili lazima waidhinishe kabla ya jukumu kubadilika. Huwezi kuidhinisha ombi lako mwenyewe.',
  "One other admin must approve before the role flips. You can't approve your own request.":
    'Msimamizi mwingine mmoja lazima aidhinishe kabla ya jukumu kubadilika. Huwezi kuidhinisha ombi lako mwenyewe.',
  'There are no other admins yet, so this change applies immediately. Once the group has more admins, role changes will need two approvals.':
    'Hakuna wasimamizi wengine bado, kwa hiyo mabadiliko haya yanatekelezwa mara moja. Kikundi kitakapokuwa na wasimamizi zaidi, mabadiliko ya jukumu yatahitaji idhini mbili.',
  'Request promotion': 'Omba upandishaji',
  'Request revocation': 'Omba uondoaji',
  'Promote now': 'Pandisha sasa',
  'Revoke now': 'Ondoa sasa',
  'Could not open the role-change request.': 'Haikuweza kufungua ombi la mabadiliko ya jukumu.',
  'A reason is required for every role change.': 'Sababu inahitajika kwa kila mabadiliko ya jukumu.',

  // Pool edit queue
  'Pending total-assets edits ({n})': 'Marekebisho ya mali jumla yanayosubiri ({n})',
  'Adjust group pool': 'Rekebisha hazina ya kikundi',
  'Current pool': 'Hazina ya sasa',
  'After edit · pool': 'Baada ya marekebisho · hazina',
  'Current total assets': 'Jumla ya mali ya sasa',
  'After edit · total assets': 'Baada ya marekebisho · mali jumla',
  'Cancel this pool edit request?': 'Ghairi ombi hili la kuhariri hazina?',

  // Request pool edit modal
  'Edit group total assets': 'Hariri jumla ya mali ya kikundi',
  'After approval: pool {pool} · total assets {total}.': 'Baada ya idhini: hazina {pool} · mali jumla {total}.',
  'e.g. recorded interest from external account, or correction of a deposit mis-entry':
    'mf. riba iliyoandikwa kutoka akaunti ya nje, au marekebisho ya kosa la kuingiza amana',
  'A reason is required for every pool edit.': 'Sababu inahitajika kwa kila marekebisho ya hazina.',
  'This would leave the pool negative ({amount}). Choose a smaller decrease.':
    'Hii itaacha hazina hasi ({amount}). Chagua kupunguza kidogo zaidi.',
  'Could not open the pool edit request.': 'Haikuweza kufungua ombi la kuhariri hazina.',

  // Meetings, attendance & social fund (migration 030)
  'Meetings & social fund': 'Mikutano na mfuko wa jamii',
  '+ Record a meeting': '+ Andika mkutano',
  'Record it': 'Iandike',
  'Date held': 'Tarehe ilipofanyika',
  'Title': 'Kichwa',
  'Minutes (optional)': 'Kumbukumbu (si lazima)',
  'e.g. Monthly meeting — March': 'mfano: Mkutano wa mwezi — Machi',
  'Give the meeting a title.': 'Ipe mkutano kichwa.',
  'Could not record the meeting.': 'Haikuweza kuandika mkutano.',
  'No meetings recorded yet.': 'Bado hakuna mikutano iliyoandikwa.',
  'Register open': 'Daftari liko wazi',
  'Fines applied': 'Faini zimetozwa',
  'present': 'yupo',
  'late': 'amechelewa',
  'excused': 'ameruhusiwa',
  'absent': 'hayupo',
  'Attendance for {name}': 'Mahudhurio ya {name}',
  'Could not save attendance.': 'Haikuweza kuhifadhi mahudhurio.',
  'Apply the fines': 'Toza faini',
  'Could not apply the fines.': 'Haikuweza kutoza faini.',
  '{amount} in fines will be deducted straight from savings. Nobody is invoiced.':
    'Faini za {amount} zitakatwa moja kwa moja kutoka akiba. Hakuna anayetumiwa ankara.',
  'Nobody is being fined for this meeting.': 'Hakuna anayetozwa faini kwa mkutano huu.',
  '{amount} in fines was deducted on {date}.': 'Faini za {amount} zilikatwa tarehe {date}.',
  'Deduct {amount} from members’ savings? This cannot be undone.':
    'Kata {amount} kutoka akiba za wanachama? Hili haliwezi kutenguliwa.',
  'Attendance fine': 'Faini ya mahudhurio',
  'Fine for arriving late': 'Faini ya kuchelewa',
  'Fine for missing a meeting': 'Faini ya kutohudhuria',
  'Social fund': 'Mfuko wa jamii',
  'Welfare money for emergencies. Kept separate from the loan pool — it is never lent out.':
    'Fedha za msaada kwa dharura. Zimetenganishwa na hazina ya mikopo — hazikopeshwi kamwe.',
  'Record a contribution': 'Andika mchango',
  'Propose a grant': 'Pendekeza msaada',
  'Choose a member…': 'Chagua mwanachama…',
  'e.g. monthly welfare contribution': 'mfano: mchango wa kila mwezi wa msaada',
  'e.g. funeral costs': 'mfano: gharama za msiba',
  'A reason is required.': 'Sababu inahitajika.',
  'Could not save that.': 'Haikuweza kuhifadhi hilo.',
  'You proposed this': 'Wewe ulipendekeza hili',
  'Save': 'Hifadhi',
  'Social fund grant proposed': 'Msaada wa mfuko wa jamii umependekezwa',
  'Social fund grant approved': 'Msaada wa mfuko wa jamii umeidhinishwa',
  'Could not load meetings. Has migration 030 been applied?':
    'Haikuweza kupakia mikutano. Je, uhamishaji 030 umetekelezwa?',

  // Group report / AGM pack (migration 029)
  'Group report': 'Ripoti ya kikundi',
  'What the group earned': 'Kikundi kilipata nini',
  'Interest on loans': 'Riba ya mikopo',
  'Net earnings': 'Faida halisi',
  'Loans issued': 'Mikopo iliyotolewa',
  'Fee payments received': 'Malipo ya ada yaliyopokelewa',
  'Fee payments are members’ own capital, not profit — they are listed here for activity only.':
    'Malipo ya ada ni mtaji wa wanachama wenyewe, si faida — yameorodheshwa hapa kwa shughuli tu.',
  'What the group holds': 'Kikundi kinamiliki nini',
  'as at {date}': 'hadi {date}',
  'Assets': 'Mali',
  'Cash in the pool': 'Fedha kwenye hazina',
  'Total assets': 'Jumla ya mali',
  'Whose it is': 'Ni ya nani',
  'Less: paid out': 'Toa: iliyolipwa',
  'Total claims': 'Jumla ya madai',
  'Assets and claims agree — the books balance.': 'Mali na madai vinalingana — hesabu ziko sawa.',
  'Off by {amount}. Resolve this before presenting these accounts.':
    'Tofauti ya {amount}. Tatua hili kabla ya kuwasilisha hesabu hizi.',
  'Members ({n})': 'Wanachama ({n})',
  // 'Capital' is already defined in the cycles section below and reused here.
  'Owes': 'Anadaiwa',
  'Fines': 'Faini',
  'Last payout': 'Malipo ya mwisho',
  'Download the report (CSV)': 'Pakua ripoti (CSV)',
  'Could not load the reports. Has migration 029 been applied?':
    'Haikuweza kupakia ripoti. Je, uhamishaji 029 umetekelezwa?',

  // Guarantees were removed in migration 035. These three strings outlived that
  // block because other screens still use them.
  'Choose a member': 'Chagua mwanachama',
  'Choose a member.': 'Chagua mwanachama.',
  'A member': 'Mwanachama',

  // Admin recording (migrations 036–037). Members file nothing; admins key it all.
  'Record monthly fees': 'Ingiza ada za mwezi',
  'Record a payment': 'Ingiza malipo',
  'File a loan': 'Fungua mkopo',
  'Open a withdrawal': 'Fungua utoaji',
  'Close': 'Funga',
  'Every fee is settled. Nothing to record.': 'Kila ada imelipwa. Hakuna cha kuingiza.',
  'Could not load the fee sheet.': 'Haikuweza kupakia orodha ya ada.',
  'Could not post the fee sheet.': 'Haikuweza kutuma orodha ya ada.',
  'Tick at least one member.': 'Chagua angalau mwanachama mmoja.',
  'Every ticked member needs an amount greater than zero.':
    'Kila mwanachama uliyemchagua anahitaji kiasi zaidi ya sifuri.',
  'Record fee for {name}': 'Ingiza ada ya {name}',
  'Amount for {name}': 'Kiasi cha {name}',
  'penalty {amount}': 'faini {amount}',
  '{n} selected · {amount}': 'Wamechaguliwa {n} · {amount}',
  'Post {n} payments': 'Tuma malipo {n}',
  'Posting…': 'Inatuma…',
  'Your own fee is not on this sheet. Record it with “Record a payment” — an admin’s own money always needs a second admin’s signature.':
    'Ada yako haiko kwenye orodha hii. Itumie “Ingiza malipo” — fedha za msimamizi mwenyewe daima zinahitaji saini ya msimamizi wa pili.',

  'Paying for': 'Malipo ya',
  'Which fee': 'Ada ipi',
  'Which installment': 'Awamu ipi',
  'Choose a member first': 'Kwanza chagua mwanachama',
  'Nothing outstanding': 'Hakuna deni',
  'Choose…': 'Chagua…',
  'you': 'wewe',
  'Enter what actually arrived, not what was owed.':
    'Weka kilichopokelewa kweli, si kilichodaiwa.',
  'Could not load what this member owes.': 'Haikuweza kupakia madeni ya mwanachama huyu.',
  'Could not record the payment.': 'Haikuweza kuingiza malipo.',
  'Recording…': 'Inaingiza…',
  'This is your own money, so a second admin must sign it — even for a monthly fee.':
    'Hizi ni fedha zako mwenyewe, hivyo msimamizi wa pili lazima asaini — hata kwa ada ya mwezi.',
  'A second admin must approve this before it posts.':
    'Msimamizi wa pili lazima aidhinishe kabla haijaingia.',
  'This posts immediately on your signature.': 'Hii inaingia mara moja kwa saini yako.',

  'Their savings': 'Akiba yao',
  'Loan amount (TSh)': 'Kiasi cha mkopo (TSh)',
  'Above the {amount} ceiling — the database will refuse to approve it.':
    'Zaidi ya kikomo cha {amount} — mfumo utakataa kuidhinisha.',
  'This only raises the request. Two admins must approve it, and the M-Pesa proof is attached at approval.':
    'Hii inafungua ombi tu. Wasimamizi wawili lazima waidhinishe, na uthibitisho wa M-Pesa unaambatishwa wakati wa idhini.',
  'Filing…': 'Inafungua…',
  'File loan': 'Fungua mkopo',
  'Could not file the loan.': 'Haikuweza kufungua mkopo.',
  'This is your own loan. Another admin must also approve it.':
    'Huu ni mkopo wako mwenyewe. Msimamizi mwingine lazima pia aidhinishe.',

  'Locked behind their loan': 'Imefungwa kwa mkopo wao',
  'Can withdraw': 'Anaweza kuondoa',
  'They can withdraw at most {amount} right now.':
    'Kwa sasa anaweza kuondoa hadi {amount}.',
  'A reason is required for every withdrawal.': 'Sababu inahitajika kwa kila utoaji.',
  'e.g. school fees': 'mfano ada ya shule',
  'Two admins must approve this, and the savings only move when the payout proof is recorded.':
    'Wasimamizi wawili lazima waidhinishe, na akiba inahama tu pale uthibitisho wa malipo unapoingizwa.',
  'Opening…': 'Inafungua…',
  'Could not open the withdrawal.': 'Haikuweza kufungua utoaji.',

  'Voided': 'Imebatilishwa',
  'No screenshot — recorded by {name}.': 'Hakuna picha — imeingizwa na {name}.',
  'No screenshot attached.': 'Hakuna picha iliyoambatishwa.',

  'Corrections': 'Marekebisho',
  'Waiting for a second signature': 'Inasubiri saini ya pili',
  'Recently recorded': 'Zilizoingizwa karibuni',
  'Void': 'Batilisha',
  'Request void': 'Omba kubatilisha',
  'Approve correction': 'Idhinisha marekebisho',
  'Awaiting another admin': 'Inasubiri msimamizi mwingine',
  'Why is this being voided?': 'Kwa nini hii inabatilishwa?',
  'Say why this entry is being voided.': 'Eleza kwa nini muamala huu unabatilishwa.',
  'A second admin must approve the correction before it applies.':
    'Msimamizi wa pili lazima aidhinishe marekebisho kabla hayajatekelezwa.',
  'Raised by {name}': 'Imefunguliwa na {name}',
  'Could not load corrections.': 'Haikuweza kupakia marekebisho.',
  'That did not work.': 'Hilo halikufanya kazi.',

  'Your membership is not active.': 'Uanachama wako haupo hai.',
  'Speak to your group admin if you think this is a mistake.':
    'Zungumza na msimamizi wa kikundi chako ikiwa unadhani kuna kosa.',

  // Member dashboard, now read-only
  'Payments are recorded by your admin. Speak to them to pay in, request a loan, or withdraw.':
    'Malipo yanaingizwa na msimamizi wako. Zungumza naye ili kuweka fedha, kuomba mkopo, au kuondoa.',
  'Read-only view. Use the admin dashboard to record a payment, file a loan, or correct an entry for this member.':
    'Mwonekano wa kusoma tu. Tumia dashibodi ya msimamizi kuingiza malipo, kufungua mkopo, au kurekebisha muamala wa mwanachama huyu.',
  'Accounts are created by your group admin. Speak to them to get access.':
    'Akaunti zinafunguliwa na msimamizi wa kikundi chako. Zungumza naye ili upate nafasi.',

  '{n}× savings': 'Mara {n} ya akiba',
  '{n}% of pool': '{n}% ya hazina',

  // Reconciliation (migration 027)
  'The group’s books do not balance': 'Hesabu za kikundi hazilingani',
  'What the group holds and what members are owed differ by {amount}. Do not close a cycle or pay anything out until this is resolved.':
    'Kile kikundi kinachomiliki na kile wanachama wanachodai vinatofautiana kwa {amount}. Usifunge mzunguko wala kulipa chochote hadi hili litatuliwe.',
  // 'Pool' is already defined in the pool-chart section above and reused here.
  'Out on loans': 'Iko kwenye mikopo',
  'Total held': 'Jumla inayomilikiwa',
  'Member capital': 'Mtaji wa wanachama',
  'Retained earnings': 'Faida iliyobaki',
  'Admin adjustments': 'Marekebisho ya msimamizi',
  'Total owed': 'Jumla inayodaiwa',
  'Difference': 'Tofauti',

  // Notification channels (migration 026)
  'Reminders': 'Vikumbusho',
  'Text message reminders': 'Vikumbusho kwa ujumbe mfupi',
  'Sent to {phone}': 'Zinatumwa kwa {phone}',
  'Add your phone number above so the group can text you.':
    'Ongeza namba yako ya simu hapo juu ili kikundi kiweze kukutumia ujumbe.',
  'Notifications on this device': 'Arifa kwenye kifaa hiki',
  'Free. Works best once you install the app to your home screen.':
    'Bure. Inafanya kazi vizuri ukiweka programu kwenye skrini yako ya nyumbani.',
  'This browser does not support notifications.': 'Kivinjari hiki hakiungi mkono arifa.',
  'Your browser did not allow notifications on this device.':
    'Kivinjari chako hakikuruhusu arifa kwenye kifaa hiki.',
  'Could not save your notification settings.': 'Haikuweza kuhifadhi mipangilio yako ya arifa.',
  'You are always reminded in the app. These are for reaching you outside it.':
    'Daima unakumbushwa ndani ya programu. Hizi ni za kukufikia nje yake.',
  'Monthly fee due soon': 'Ada ya mwezi inakaribia kuisha muda',
  'Monthly fee overdue': 'Ada ya mwezi imechelewa',
  'Loan repayment due soon': 'Marejesho ya mkopo yanakaribia',
  'Loan repayment overdue': 'Marejesho ya mkopo yamechelewa',
  'Your share-out is waiting': 'Mgao wako unakusubiri',

  // Cycles & share-out (migrations 023–024)
  'Cycles & share-out': 'Mizunguko na mgao',
  'Open': 'Wazi',
  'Closed': 'Imefungwa',
  'Interest earned': 'Riba iliyopatikana',
  'Penalties collected': 'Faini zilizokusanywa',
  'Written off': 'Zilizofutwa',
  'Net earnings to share': 'Faida halisi ya kugawana',
  'Close this cycle': 'Funga mzunguko huu',
  'Earnings only': 'Faida pekee',
  'Full share-out': 'Mgao kamili',
  'Profit is paid out; everyone’s savings roll into the next cycle.':
    'Faida inalipwa; akiba ya kila mmoja inaendelea kwenye mzunguko ujao.',
  'Profit AND savings go back to members. Every loan must be settled first.':
    'Faida NA akiba zinarudi kwa wanachama. Kila mkopo lazima ulipwe kwanza.',
  'Preview the split': 'Angalia mgawanyo',
  'Could not build the preview.': 'Haikuweza kuandaa muhtasari.',
  // 'Member' and 'Requested {date}' are already defined in the member-grid and
  // deletion-queue sections above and are reused verbatim here.
  'Share': 'Sehemu',
  'Earnings': 'Faida',
  'Capital': 'Mtaji',
  'Payout': 'Malipo',
  'Total payout': 'Jumla ya malipo',
  'Shares are weighted by how long each member’s money was in the group, not just their closing balance.':
    'Sehemu zinapimwa kwa muda ambao fedha za kila mwanachama zilikuwa kwenye kikundi, si salio la mwisho tu.',
  'e.g. agreed at the annual general meeting on 12 December':
    'mfano: ilikubaliwa kwenye mkutano mkuu wa mwaka tarehe 12 Desemba',
  'A reason is required to close a cycle.': 'Sababu inahitajika kufunga mzunguko.',
  'Could not open the closure request.': 'Haikuweza kufungua ombi la kufunga.',
  'Two other admins must approve. Closing freezes every figure above — later corrections cannot change an agreed share-out.':
    'Wasimamizi wengine wawili lazima waidhinishe. Kufunga kunaganda takwimu zote hapo juu — marekebisho ya baadaye hayawezi kubadilisha mgao uliokubaliwa.',
  'Propose closing this cycle': 'Pendekeza kufunga mzunguko huu',
  'Cycle close awaiting approval': 'Kufunga mzunguko kunasubiri idhini',
  'Approve & close': 'Idhinisha na funga',
  'Cycle close proposed': 'Kufunga mzunguko kumependekezwa',
  'Your share-out is ready': 'Mgao wako uko tayari',
  'Share-out paid': 'Mgao umelipwa',
  '{n} payout(s) still to make': 'Malipo {n} bado hayajafanyika',
  'All payouts recorded': 'Malipo yote yameandikwa',
  '{earnings} earnings': 'faida {earnings}',
  '{capital} capital': 'mtaji {capital}',
  'Pay': 'Lipa',
  'Record payout': 'Andika malipo',
  'Upload the payout screenshot.': 'Pakia picha ya malipo.',
  'Could not record the payout.': 'Haikuweza kuandika malipo.',
  'Another admin must record your own payout.': 'Msimamizi mwingine lazima aandike malipo yako.',
  'No cycles yet.': 'Bado hakuna mizunguko.',
  'Could not load cycles. Has migration 023 been applied?':
    'Haikuweza kupakia mizunguko. Je, uhamishaji 023 umetekelezwa?',

  // Withdrawals & member exit (migration 025)
  'Withdraw savings': 'Toa akiba',
  'Held against your loan': 'Imeshikiliwa dhidi ya mkopo wako',
  'Available now': 'Inapatikana sasa',
  'Your savings are held as security while your loan is open.':
    'Akiba yako imeshikiliwa kama dhamana wakati mkopo wako uko wazi.',
  'There is nothing available to withdraw right now.': 'Hakuna kinachopatikana kutoa kwa sasa.',
  'Why do you need to withdraw?': 'Kwa nini unahitaji kutoa?',
  'Request withdrawal': 'Omba kutoa',
  'You can withdraw at most {amount} right now.':
    'Unaweza kutoa kiwango cha juu cha {amount} kwa sasa.',
  'Could not submit your withdrawal request.': 'Haikuweza kutuma ombi lako la kutoa.',
  'Approved — the admins will pay this out and attach the proof.':
    'Imeidhinishwa — wasimamizi watalipa na kuambatanisha uthibitisho.',
  'Two admins must approve before this can be paid out.':
    'Wasimamizi wawili lazima waidhinishe kabla ya kulipwa.',
  'Withdrawals ({n})': 'Utoaji ({n})',
  'exit settlement': 'malipo ya kuondoka',
  'Withdrawal requested': 'Utoaji umeombwa',
  'Withdrawal approved': 'Utoaji umeidhinishwa',
  'Withdrawal rejected': 'Utoaji umekataliwa',
  'Withdrawal paid': 'Utoaji umelipwa',
  'This is your own withdrawal — another admin must handle it.':
    'Huu ni utoaji wako mwenyewe — msimamizi mwingine lazima aushughulikie.',
  'Paying this out settles the member in full and deactivates them. Their history is kept.':
    'Kulipa hii kunamaliza mwanachama kikamilifu na kumzima. Historia yake inabaki.',
  'Could not complete that.': 'Haikuweza kukamilisha hilo.',
  'Settle & exit': 'Maliza na ondoka',
  'Settle & exit member': 'Maliza na mwondoe mwanachama',
  'Settlement': 'Malipo ya mwisho',
  'Still owes': 'Bado anadaiwa',
  'They cannot leave with an open loan. Settle it, recover it from their savings, or write it off first.':
    'Hawezi kuondoka na mkopo wazi. Ulipe, urejeshe kutoka akiba yake, au uufute kwanza.',
  'This opens a withdrawal for their full balance. Once two admins approve and the payout is recorded, they leave the group — their history is kept.':
    'Hii inafungua utoaji wa salio lake lote. Wasimamizi wawili wakiidhinisha na malipo yakiandikwa, anaondoka kwenye kikundi — historia yake inabaki.',
  'e.g. moving to Mwanza; leaving the group at the end of the cycle':
    'mfano: anahamia Mwanza; anaondoka kikundini mwisho wa mzunguko',
  'A reason is required to exit a member.': 'Sababu inahitajika kumwondoa mwanachama.',
  'Could not work out their settlement.': 'Haikuweza kukokotoa malipo yake ya mwisho.',
  'Could not open the exit request.': 'Haikuweza kufungua ombi la kuondoka.',
  'Open exit settlement': 'Fungua malipo ya kuondoka',
  'Member exit proposed': 'Kuondoka kwa mwanachama kumependekezwa',

  // Partial payments (migration 021)
  'Part paid': 'Imelipwa kwa sehemu',
  '{amount} already paid': '{amount} tayari imelipwa',
  '{amount} is owed. You can pay less — whatever you pay is applied to the penalty first, then the balance.':
    'Unadaiwa {amount}. Unaweza kulipa kidogo — unachokilipa kinaenda kwenye faini kwanza, kisha salio.',
  'Only {amount} is owed. Log anything extra as a savings deposit instead.':
    'Unadaiwa {amount} tu. Ziada yoyote iingize kama amana ya akiba.',
  'to penalty': 'kwa faini',
  'to interest': 'kwa riba',
  'to the fee': 'kwa ada',
  'to principal': 'kwa mtaji',
  'to principal (early)': 'kwa mtaji (mapema)',
  '{amount} will still be owed — marked part paid.':
    '{amount} bado itadaiwa — itawekwa kama imelipwa kwa sehemu.',
  'Settles this in full.': 'Inamaliza hii kikamilifu.',
  '{amount} more than anything outstanding. Approve the exact amount and log the surplus as a savings deposit.':
    '{amount} zaidi ya deni lolote lililopo. Idhinisha kiasi halisi na ziada iingize kama amana ya akiba.',

  // Loan distress actions (migration 022)
  'Active loans ({n})': 'Mikopo inayoendelea ({n})',
  '{n} at risk': '{n} iko hatarini',
  'On schedule': 'Inaenda sawa',
  '{n} overdue · {d} days': '{n} zimechelewa · siku {d}',
  '+ {amount} penalty': '+ faini ya {amount}',
  'Action': 'Hatua',
  'Action pending': 'Hatua inasubiri',
  'Loan action': 'Hatua ya mkopo',
  'Borrower': 'Mkopaji',
  'Outstanding': 'Deni lililobaki',
  'Overdue installments': 'Awamu zilizochelewa',
  'Reschedule the loan': 'Panga upya mkopo',
  'Recover from their savings': 'Rejesha kutoka akiba yao',
  'Write off the balance': 'Futa salio',
  'New term (months)': 'Muda mpya (miezi)',
  'Term must be between 1 and 24 months.': 'Muda lazima uwe kati ya miezi 1 na 24.',
  'A reason is required for every loan action.': 'Sababu inahitajika kwa kila hatua ya mkopo.',
  'This member has no savings to recover from.': 'Mwanachama huyu hana akiba ya kurejesha.',
  'At most {amount} can be recovered (the lower of the balance owed and their savings).':
    'Kiasi cha juu kinachoweza kurejeshwa ni {amount} (kidogo kati ya deni na akiba yao).',
  'Could not open the loan action request.': 'Haikuweza kufungua ombi la hatua ya mkopo.',
  'Submit action': 'Tuma hatua',
  'A new schedule is cut over {n} month(s) on the {amount} still outstanding. Unpaid installments are cancelled, which also cancels the penalty they had accrued.':
    'Ratiba mpya inaandaliwa kwa miezi {n} kwa {amount} inayodaiwa. Awamu ambazo hazijalipwa zinafutwa, pamoja na faini zilizokusanyika.',
  'Up to {amount}. Their savings drop by this amount and the loan balance falls with it — no cash moves.':
    'Hadi {amount}. Akiba yao inapungua kwa kiasi hiki na deni la mkopo linapungua nalo — hakuna fedha inayohama.',
  'The group permanently absorbs the {amount} still owed. The pool falls by that amount and the debt is closed.':
    'Kikundi kinabeba hasara ya {amount} inayodaiwa. Hazina inapungua kwa kiasi hicho na deni linafungwa.',
  'e.g. lost their job in March; agreed a longer repayment at the April meeting':
    'mfano: alipoteza kazi Machi; ilikubaliwa marejesho ya muda mrefu kwenye mkutano wa Aprili',
  'Pending loan actions ({n})': 'Hatua za mikopo zinazosubiri ({n})',
  'Cancel this loan action request?': 'Ghairi ombi hili la hatua ya mkopo?',
  'Could not approve the action.': 'Imeshindwa kuidhinisha hatua.',
  'This is your own loan — you cannot vote on it.': 'Huu ni mkopo wako — huwezi kupiga kura juu yake.',
  'Reschedule {name}’s loan': 'Panga upya mkopo wa {name}',
  'Write off {name}’s loan': 'Futa mkopo wa {name}',
  'Recover from {name}’s savings': 'Rejesha kutoka akiba ya {name}',
  'New schedule over {n} month(s) on {amount} outstanding. Unpaid installments and their accrued penalty are cancelled.':
    'Ratiba mpya ya miezi {n} kwa {amount} inayodaiwa. Awamu ambazo hazijalipwa na faini zake zinafutwa.',
  'The pool permanently absorbs {amount}.': 'Hazina inabeba hasara ya {amount} kudumu.',
  '{amount} moves from their savings to the loan balance. No cash moves.':
    '{amount} inahama kutoka akiba yao kwenda deni la mkopo. Hakuna fedha inayohama.',
  'Loan rescheduled': 'Mkopo umepangwa upya',
  'Loan written off': 'Mkopo umefutwa',
  'Loan settled from your savings': 'Mkopo umelipwa kutoka akiba yako',
  'Loan action proposed': 'Hatua ya mkopo imependekezwa',

  // Group rules / settings (migration 020). The rule labels come from the
  // group_settings.label column, so they are translated by value here.
  'Group rules': 'Kanuni za kikundi',
  'Propose change': 'Pendekeza mabadiliko',
  'Change a group rule': 'Badilisha kanuni ya kikundi',
  'Rule': 'Kanuni',
  'Current value': 'Thamani ya sasa',
  'Allowed range': 'Kiwango kinachoruhusiwa',
  'New value': 'Thamani mpya',
  'New value (%)': 'Thamani mpya (%)',
  'Enter a new value.': 'Weka thamani mpya.',
  'That is already the current value.': 'Hiyo tayari ndiyo thamani ya sasa.',
  'Must be between {min} and {max}.': 'Lazima iwe kati ya {min} na {max}.',
  'A reason is required for every rule change.': 'Sababu inahitajika kwa kila mabadiliko ya kanuni.',
  'Could not open the rule change request.': 'Haikuweza kufungua ombi la mabadiliko ya kanuni.',
  '{label}: {from} → {to}': '{label}: {from} → {to}',
  'e.g. agreed at the January meeting to raise the monthly fee':
    'mfano: ilikubaliwa kwenye mkutano wa Januari kupandisha ada ya kila mwezi',
  "Two other admins must approve this change before it applies. You can't approve your own request.":
    'Wasimamizi wengine wawili lazima waidhinishe mabadiliko haya kabla hayajaanza kutumika. Huwezi kuidhinisha ombi lako mwenyewe.',
  'New rules apply to future fees and loans only — penalties and interest already charged never change.':
    'Kanuni mpya zinahusu ada na mikopo ya baadaye pekee — faini na riba zilizokwisha tozwa hazibadiliki kamwe.',
  'Changing a rule needs two admin approvals and applies to future fees and loans only.':
    'Kubadilisha kanuni kunahitaji idhini ya wasimamizi wawili na kunahusu ada na mikopo ya baadaye pekee.',
  'Pending rule changes ({n})': 'Mabadiliko ya kanuni yanayosubiri ({n})',
  'Cancel this rule change request?': 'Ghairi ombi hili la mabadiliko ya kanuni?',
  'Could not approve the change.': 'Imeshindwa kuidhinisha mabadiliko.',
  'Applies to future fees and loans only.': 'Inahusu ada na mikopo ya baadaye pekee.',
  'Monthly fee (TZS)': 'Ada ya kila mwezi (TZS)',
  'Monthly loan interest': 'Riba ya mkopo kwa mwezi',
  'Monthly overdue penalty': 'Faini ya kuchelewa kwa mwezi',
  'Max share of pool per loan': 'Kiwango cha juu cha hazina kwa mkopo mmoja',
  'Loan cap as multiple of contribution': 'Ukomo wa mkopo kwa mara ya mchango',
  'Loan term (months)': 'Muda wa mkopo (miezi)',
  'Group rule changed': 'Kanuni ya kikundi imebadilika',
  'Rule change proposed': 'Mabadiliko ya kanuni yamependekezwa',

  // Pool chart
  'Group pool over time': 'Hazina ya kikundi kwa wakati',
  'Could not load the chart.': 'Haikuweza kupakia chati.',
  'No history yet. Approve a payment to see the chart fill in.':
    'Hakuna historia bado. Idhinisha malipo ili kuona chati.',
  'Pool': 'Hazina',

  // Member summary cards
  'My savings': 'Akiba yangu',
  'My loan balance': 'Salio la mkopo wangu',
  'Request pending': 'Ombi linasubiri',
  'Repaid {amount} of {total}': 'Imelipwa {amount} kati ya {total}',
  'Amount due': 'Kiasi kinachostahili',
  'Incl. {penalty} penalty': 'Ikiwa na faini ya {penalty}',
  'Max loan you can request': 'Mkopo wa juu unaoeza kuomba',
  'Make a savings deposit or pay your monthly fee to become eligible.':
    'Weka amana ya akiba au lipa ada yako ya kila mwezi ili kustahili.',
  'Group pool is currently too low to issue a loan.': 'Hazina ya kikundi iko chini sana kutoa mkopo kwa sasa.',
  // {n} is the live contribution multiplier / pool percentage from group_settings,
  // so these read correctly after the group votes to change either rule.
  'Limited by {n}× your savings.': 'Imezuiwa na mara {n} ya akiba yako.',
  'Both rules cap at the same amount.': 'Sheria zote mbili zinafikia kiasi sawa.',
  'Limited by {n}% of the group pool.': 'Imezuiwa na {n}% ya hazina ya kikundi.',
  'Available once your current loan is closed.': 'Itapatikana mkopo wako wa sasa ukifungwa.',

  // Obligations card
  'This month': 'Mwezi huu',
  'Pay these to keep your account in good standing.': 'Lipa hizi ili akaunti yako ibaki katika hali nzuri.',
  'Membership fee': 'Ada ya uanachama',
  'Loan installment {n}': 'Awamu ya mkopo {n}',
  'Principal + interest': 'Mtaji + riba',
  'Interest': 'Riba',
  '+ {penalty} penalty': '+ faini ya {penalty}',

  // Loan request form
  'Loan': 'Mkopo',
  'Your request for {amount} is awaiting admin approval.': 'Ombi lako la {amount} linasubiri idhini ya msimamizi.',
  'You have an active loan of {amount}. Repay it before requesting another.':
    'Una mkopo unaoendelea wa {amount}. Ulipe kabla ya kuomba mwingine.',
  'Request a loan': 'Omba mkopo',
  '{n}× your savings': 'Mara {n} ya akiba yako',
  '{n}% of group pool': '{n}% ya hazina ya kikundi',
  'Maximum you can request': 'Kiwango cha juu unachoweza kuomba',
  'Make a savings deposit or pay your monthly fee to become eligible for a loan.':
    'Weka amana ya akiba au lipa ada yako ya kila mwezi ili kustahili mkopo.',
  'The group pool is too low to issue a loan right now.': 'Hazina ya kikundi iko chini sana kutoa mkopo kwa sasa.',
  'Exceeds the maximum of {amount} ({limit}).': 'Inazidi kiwango cha juu cha {amount} ({limit}).',
  'Submit request': 'Tuma ombi',
  'Could not submit your request.': 'Haikuweza kutuma ombi lako.',

  // Log transaction sheet
  'Log a transaction': 'Ingiza muamala',
  'Savings': 'Akiba',
  'Which fee?': 'Ada ipi?',
  'Select a month…': 'Chagua mwezi…',
  '(incl. penalty)': '(ikiwa na faini)',
  'No outstanding fees.': 'Hakuna ada zinazobaki.',
  'Which installment?': 'Awamu ipi?',
  'Select an installment…': 'Chagua awamu…',
  'No installments to pay.': 'Hakuna awamu za kulipa.',
  'Amount paid (TSh)': 'Kiasi kilicholipwa (TSh)',
  'Amount': 'Kiasi',
  'Payment proof': 'Uthibitisho wa malipo',
  'Enter a valid amount.': 'Weka kiasi sahihi.',
  'Upload a payment screenshot.': 'Pakia picha ya skrini ya malipo.',
  'Choose which fee you are paying.': 'Chagua ada unayolipa.',
  'Choose which installment you are paying.': 'Chagua awamu unayolipa.',
  'Submit for approval': 'Tuma kwa idhini',
  'Could not submit. Please try again.': 'Haikuweza kutuma. Tafadhali jaribu tena.',

  // Repayment schedule
  'Repayment schedule': 'Ratiba ya malipo',
  'Cancelled — loan closed early': 'Imeghairiwa — mkopo umefungwa mapema',
  'Due {date}': 'Inastahili {date}',
  'Repaid {amount} principal': 'Imelipwa mtaji wa {amount}',

  // History
  'History': 'Historia',
  'No submissions yet.': 'Hakuna uwasilishaji bado.',
  'Sent {date}': 'Ilitumwa {date}',
  'reviewed {date}': 'ilipitiwa {date}',
  'Reason: {reason}': 'Sababu: {reason}',

  // Savings chart
  'My savings over time': 'Akiba yangu kwa wakati',

  // Loan progress bar
  'Loan progress': 'Maendeleo ya mkopo',
  '{paid} / {total} paid': '{paid} / {total} imelipwa',
  'Installment {n}: {status}': 'Awamu {n}: {status}',
  'Next: installment {n} · {amount} due {date}': 'Inayofuata: awamu {n} · {amount} inastahili {date}',
  'All installments paid — loan will close shortly.': 'Awamu zote zimelipwa — mkopo utafungwa hivi karibuni.',

  // Badge
  'Paid': 'Imelipwa',
  'Approved': 'Imeidhinishwa',
  'Pending': 'Inasubiri',
  'Overdue': 'Imechelewa',
  'Rejected': 'Imekataliwa',
  'Not due': 'Haijafika wakati',
  'Cancelled': 'Imeghairiwa',
  'N/A': 'H/M',
  'Queued': 'Foleni',
  'Sent': 'Imetumwa',

  // Upload zone
  'Tap to upload screenshot': 'Gonga ili kupakia picha ya skrini',
  'JPG, PNG, or WebP — up to 5 MB': 'JPG, PNG, au WebP — hadi 5 MB',
  'Selected:': 'Imechaguliwa:',

  // Notifications
  'Notifications': 'Arifa',
  'Mark all read': 'Soma zote',
  'No notifications yet.': 'Hakuna arifa bado.',
  'just now': 'sasa hivi',
  '{n}m ago': 'dakika {n} zilizopita',
  '{n}h ago': 'saa {n} zilizopita',
  '{n}d ago': 'siku {n} zilizopita',

  // Group members directory (transparency)
  'Group members': 'Wanachama wa kikundi',
  'Every member can see every member’s savings and loans. Full transparency keeps the group accountable.':
    'Kila mwanachama anaweza kuona akiba na mikopo ya kila mwanachama. Uwazi kamili huweka kikundi kuwajibika.',
  'Loan balance': 'Salio la mkopo',
  'You': 'Wewe',
  'Could not load members.': 'Haikuweza kupakia wanachama.',

  // Modal

  // Mobile tab bar. Kept short — the labels sit under a 22px icon in a quarter
  // of the screen width, so anything longer than ~10 characters truncates.
  'Home': 'Nyumbani',
  'Admin': 'Msimamizi',
  'Main navigation': 'Urambazaji mkuu',
  'No members yet.': 'Bado hakuna wanachama.',

  // Messaging (026/032) — the audit log and the delivery warning
  'Queued due reminders': 'Vikumbusho vimepangwa',
  'Sent reminders': 'Vikumbusho vimetumwa',
  'Scheduled reminder delivery': 'Ratiba ya kutuma vikumbusho',
  'queued for delivery': 'vimepangwa kutumwa',
  'week': 'wiki',
  'sent': 'vimetumwa',
  'failed': 'vimeshindikana',
  'skipped': 'vimerukwa',
  'expired unsent': 'vimepitwa na wakati',
  'every': 'kila',
  'Reminders are not reaching members': 'Vikumbusho havifiki kwa wanachama',
  'Some reminders could not be delivered': 'Baadhi ya vikumbusho havikutumwa',
  '{n} message(s) have been waiting more than two hours. Members are not being reminded.':
    'Jumbe {n} zimesubiri zaidi ya saa mbili. Wanachama hawapati vikumbusho.',
  '{n} message(s) failed in the last 7 days.':
    'Jumbe {n} zimeshindikana katika siku 7 zilizopita.',
  'The SMS account is out of credit. Top it up and the queue will clear itself.':
    'Akaunti ya SMS imeishiwa salio. Ongeza salio na foleni itajisafisha yenyewe.',
  'Last error': 'Hitilafu ya mwisho',
  'Nothing is lost — members still see everything in the app.':
    'Hakuna kilichopotea — wanachama bado wanaona kila kitu kwenye programu.',
}

export function createTranslator(lang) {
  return function t(key) {
    if (lang !== 'sw') return key
    return sw[key] ?? key
  }
}
