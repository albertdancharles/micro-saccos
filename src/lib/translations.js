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
  "Includes your savings deposits, paid monthly fees, and any admin-approved adjustments. Your loan ceiling is 5× this amount (capped at 25% of the group pool).":
    'Inajumuisha amana za akiba, ada za kila mwezi zilizolipwa, na marekebisho yoyote ya msimamizi. Kiwango chako cha mkopo ni mara 5 ya kiasi hiki (kiwango cha 25% ya hazina ya kikundi).',
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
  'Monthly fee': 'Ada ya kila mwezi',
  'Loan interest': 'Riba ya mkopo',
  'Overall': 'Jumla',
  'Actions': 'Vitendo',
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
  'Limited by 3× your savings.': 'Imezuiwa na mara 3 ya akiba yako.',
  'Both rules cap at the same amount.': 'Sheria zote mbili zinafikia kiasi sawa.',
  'Limited by 25% of the group pool.': 'Imezuiwa na 25% ya hazina ya kikundi.',
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
  '5× your savings': 'Mara 5 ya akiba yako',
  '25% of group pool': '25% ya hazina ya kikundi',
  '25% of the group pool': '25% ya hazina ya kikundi',
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
  'Close': 'Funga',
}

export function createTranslator(lang) {
  return function t(key) {
    if (lang !== 'sw') return key
    return sw[key] ?? key
  }
}
