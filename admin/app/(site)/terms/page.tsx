import { APP_NAME, SUPPORT_EMAIL } from '@/lib/site';

export const metadata = { title: 'Terms, refunds & community rules' };

export default function Terms() {
  const mail = <a className="underline" href={`mailto:${SUPPORT_EMAIL}`}>{SUPPORT_EMAIL}</a>;
  return (
    <main className="mx-auto max-w-3xl space-y-4 px-4 text-slate-300 [&_h1]:text-3xl [&_h1]:font-bold [&_h1]:text-white [&_h2]:mt-6 [&_h2]:text-xl [&_h2]:font-semibold [&_h2]:text-white [&_li]:mt-1">
      <h1>Terms of service</h1>
      <p>Last updated: 25 November 2026. These terms are an agreement between you and {APP_NAME} (“we”, “us”). By installing or using the app or this website you agree to them.
        Please also read our <a className="underline" href="/privacy">Privacy policy</a> and <a className="underline" href="/refund">Refund policy</a>.</p>

      <h2>1. Who can use {APP_NAME}</h2>
      <ul className="list-disc pl-6">
        <li>You must be 18 or older.</li>
        <li>You must follow the laws that apply to you, and not be barred from using online services.</li>
        <li>We may suspend or close accounts that break these terms.</li>
      </ul>

      <h2>2. Your account</h2>
      <ul className="list-disc pl-6">
        <li>You can start as a guest and add an email and password to the same account later. Some features (uploading, creating channels) need a saved account.</li>
        <li>Keep your password safe; you are responsible for activity on your account. Tell us if you think someone else is using it.</li>
        <li>Give us accurate information.</li>
      </ul>

      <h2>3. Your content</h2>
      <p>You keep ownership of what you upload. You give us a limited, non-exclusive licence to store, process and show it only as needed to run {APP_NAME} (for example to show your channel to other users).
        You are responsible for what you upload and confirm you have the right to share it. We do not review everything, but we act on reports.</p>

      <h2>4. Channels and partner content</h2>
      <ul className="list-disc pl-6">
        <li>New channels are reviewed before they go live. We choose whether channels and videos are shown to everyone, to ads installs or to organic installs; a paid plan does not override these rules.</li>
        <li>Some channels and videos are supplied by our content partner Flixvault. We may hide any of them in {APP_NAME}; you can follow, block or report them like other channels.</li>
        <li>Channel owners are responsible for their channels. We may hide, restrict or remove a channel, or suspend its owner, when the rules are broken.</li>
      </ul>

      <h2>5. Cloud storage</h2>
      <p>Free accounts get a limited quota; paid plans raise it. If a plan ends, your existing files stay, but you may not be able to add files above the free quota. Keep your own copy of important files.</p>

      <h2>6. Plans and payments</h2>
      <p>Plans are paid in Indian rupees through UPI. A plan starts when your payment is confirmed and runs for the duration shown at purchase. Plans do not renew automatically.
        A new purchase is added after your current end date. The price and duration shown at the time of purchase apply to that order. We may end a plan if the account breaks these terms.</p>

      <h2 id="refunds">7. Refunds</h2>
      <p>If money left your account but the plan did not activate within 24 hours, email {mail} with the reference shown in the app and we will activate it or refund in full within 7 working days.
        Other refunds are given if you ask within 48 hours of purchase and have not used more than 15 GB of storage. See the <a className="underline" href="/refund">Refund policy</a>.</p>

      <h2>8. Notifications and measurement</h2>
      <p>If you allow notifications, we send messages about new videos, your payments and your plan, and occasional offers, as described in the <a className="underline" href="/privacy">Privacy policy</a>.
        You can turn them off in your phone&apos;s settings at any time. We measure our Meta ads as described there; this never changes what your plan includes.</p>

      <h2 id="community">9. Community rules</h2>
      <ul className="list-disc pl-6">
        <li>No sexual or nude content, no content involving minors — ever.</li>
        <li>No violence, hate, harassment, scams or spam.</li>
        <li>Only upload content you own or have the rights to.</li>
        <li>We review new channels and may hide content or close accounts that break these rules.</li>
      </ul>

      <h2>10. Acceptable use</h2>
      <p>Do not break the law, hack, overload or disrupt the service, get around its limits, tamper with the app, fake payments or use {APP_NAME} for fraud. Do not misuse other people&apos;s information or send spam.</p>

      <h2 id="copyright">11. Copyright</h2>
      <p>To report copyright infringement, use the report button in the app or the <a className="underline" href="/report-content">report-content</a> page, with proof of ownership.
        We remove infringing content and close repeat-infringer accounts. Watching or downloading content does not give you ownership of it.</p>

      <h2>12. Third-party services</h2>
      <p>{APP_NAME} relies on third-party services (listed in the Privacy policy) and may link to other websites. We do not control them and are not responsible for their content or policies.</p>

      <h2>13. Ending your use</h2>
      <p>You can delete your account at any time (see <a className="underline" href="/delete-account">Delete account</a>). Some records are kept as explained in the Privacy policy.</p>

      <h2>14. Liability</h2>
      <p>{APP_NAME} is provided “as is”. We work to keep it running but cannot promise it will be uninterrupted or error-free. Keep a copy of important files.
        To the extent the law allows, our liability is limited to the amount you paid in the last 12 months. Nothing here limits rights that cannot be excluded by law.</p>

      <h2>15. Changes</h2>
      <p>We may update these terms; the date above shows the latest version. Continuing to use {APP_NAME} after a change means you accept it.</p>

      <p>Contact: {mail}</p>
    </main>
  );
}
