import { APP_NAME, SUPPORT_EMAIL } from '@/lib/site';

export const metadata = { title: 'Privacy policy' };

export default function Privacy() {
  const mail = <a className="underline" href={`mailto:${SUPPORT_EMAIL}`}>{SUPPORT_EMAIL}</a>;
  return (
    <main className="prose-invert mx-auto max-w-3xl space-y-4 px-4 text-slate-300 [&_h1]:text-3xl [&_h1]:font-bold [&_h1]:text-white [&_h2]:mt-6 [&_h2]:text-xl [&_h2]:font-semibold [&_h2]:text-white [&_li]:mt-1">
      <h1>Privacy policy</h1>
      <p>Last updated: 25 November 2026. This policy explains what {APP_NAME} collects through the Android app and this website, why, who we share it with, and the choices you have.</p>

      <h2>Who we are</h2>
      <p>{APP_NAME} provides an Android app with private cloud storage and creator channels, and this website. For any privacy question, write to {mail}.</p>

      <h2>Information needed to run {APP_NAME}</h2>
      <ul className="list-disc pl-6">
        <li><b>Account:</b> an anonymous user id when you start as a guest; your email address and password if you create an account (the password is handled by our sign-in provider and never shared); a display name and avatar if you add them.</li>
        <li><b>Your files:</b> photos, videos and documents you upload. They are stored privately and only you can open them, through short-lived signed links. We never use your files for advertising.</li>
        <li><b>Channels and videos:</b> channels you create or follow, posts you publish, channels you block and reports you send. Some channels and videos come from our content partner Flixvault; your follows, blocks and reports for them are kept by {APP_NAME} and are not sent to Flixvault.</li>
        <li><b>Payments:</b> plan, amount, order reference, payment status and dates, and the UPI transaction id or UTR returned by your UPI app or typed by you, plus a payment screenshot only if you choose to upload one. We never see or store your bank account, card or UPI PIN.</li>
        <li><b>Install source:</b> a random install id and whether the app was installed from one of our ad links (including campaign labels such as utm_source), used to show the right content and plans and to measure our ads.</li>
        <li><b>Device check (Google Play version):</b> a Google Play Integrity result confirming the app is genuine, used to give free storage and prevent abuse.</li>
        <li><b>Support and safety:</b> requests you send us, and technical and security logs (which can include IP address and browser or device information).</li>
      </ul>
      <p>We do not collect your contacts, messages, call logs or precise location.</p>

      <h2>Push notifications</h2>
      <p>If you allow notifications, the app registers a notification token from Google Firebase Cloud Messaging and stores it with your account. We use it to send:</p>
      <ul className="list-disc pl-6">
        <li>messages we send to all users or a group of users (for example everyone, ads or organic installs, paid or free users), such as new videos or offers;</li>
        <li>automatic messages: a welcome message, new-video announcements, daily suggestions in your first days, a reminder if you have not opened the app for a while,
          payment reminders for an unfinished payment, payment failed or plan activated, and notices before and after your plan ends.</li>
      </ul>
      <p>Messages only show content you are allowed to see. We do not send automatic messages during quiet hours (India time) and we limit how many you receive.
        We record whether each message was delivered and whether it was tapped, to improve them. You can turn notifications off at any time in your phone&apos;s settings; deleting your account deletes your tokens.</p>

      <h2>Measurement with Meta (Facebook and Instagram)</h2>
      <p>We advertise {APP_NAME} on Meta and measure which ads lead to downloads, installs, sign-ups and purchases.</p>
      <ul className="list-disc pl-6">
        <li><b>Website:</b> when measurement is on, our download pages (/d and /get) load the Meta Pixel. It records a page view and a tap on the Download button, and Meta may set its cookies (_fbp, _fbc).
          Our server also sends the same Download event to Meta (Conversions API) with your IP address, browser user agent, Meta click id (fbclid / _fbc), _fbp and campaign labels; both carry one event id so Meta counts it once.
          A Download tap does not prove that the app was installed.</li>
        <li><b>App:</b> only for installs that came from one of our Meta ads, we may send Meta events such as first open, registration, starting a payment and a verified purchase (plan and amount in INR),
          with a hashed (SHA-256) email address and a hashed user id. If you allow advertising measurement in the app, we may also send your device&apos;s advertising ID (only while ad personalisation is not turned off on your phone)
          and Meta&apos;s anonymous app id, so Meta can match the install to the ad. Users who did not come from such an ad, including everyone who installs from Google Play without an ad, are not reported to Meta.</li>
        <li><b>Never shared:</b> your files, file names, passwords, UPI PIN, bank details, payment screenshots or UPI replies.</li>
      </ul>
      <p>Hashed identifiers are pseudonymised, not anonymous: Meta may match them with information it already has to attribute and improve ads, under <a className="underline" href="https://www.facebook.com/privacy/policy/" target="_blank" rel="noreferrer">Meta&apos;s Privacy Policy</a>.
        Purchases are only sent after the payment is verified. You can use Meta&apos;s own ad settings, block cookies in your browser, reset or delete your advertising ID in your phone&apos;s settings, or ask us to stop at {mail}.
        Refusing measurement never changes your plan, storage or the content you can see.</p>

      <h2>Service providers</h2>
      <ul className="list-disc pl-6">
        <li><b>Supabase:</b> sign-in, database, file storage and server functions.</li>
        <li><b>Vercel:</b> website hosting.</li>
        <li><b>Google Firebase Cloud Messaging:</b> delivering push notifications.</li>
        <li><b>Meta:</b> ad measurement as described above.</li>
        <li><b>Flixvault:</b> supplies partner channels and videos; we do not send it your personal data.</li>
        <li><b>UPI apps, banks and Google Play:</b> when you pay or install through them, under their own policies.</li>
      </ul>
      <p>We do not sell your data. We may disclose data when the law requires it, to prevent fraud or abuse, or to protect people. Providers may process data outside India under their own safeguards.</p>

      <h2>Security</h2>
      <p>All connections use HTTPS. Files are private by default and access rules are enforced on our servers. No system is perfectly secure, so keep a copy of important files and keep your password private.</p>

      <h2>Retention and deletion</h2>
      <ul className="list-disc pl-6">
        <li>Account, files and channels: until you delete them or your account.</li>
        <li>Notification tokens: until they stop working, you log out, or you delete your account. Message delivery statistics are kept in summary form.</li>
        <li>Ad-click and measurement records: only as long as needed to measure our ads.</li>
        <li>Payment records (amount, date, reference, transaction id): 8 years as required by Indian tax law, without your name or files.</li>
      </ul>
      <p>You can delete your account in the app (profile icon › Settings › Delete Account) or at <a className="underline" href="/delete-account">/delete-account</a>.</p>

      <h2>Children</h2>
      <p>{APP_NAME} is for people aged 18 and over. We do not knowingly collect data from children; if you believe a child has an account, contact us and we will delete it.</p>

      <h2>Your rights</h2>
      <p>Ask for a copy, correction or deletion of your data, or for us to stop ad measurement, at {mail} with the subject “Privacy request”. We may need to confirm the account is yours first.</p>

      <h2>Changes</h2>
      <p>We will update this page and the date at the top when this policy changes, and tell you in the app about important changes.</p>
    </main>
  );
}
