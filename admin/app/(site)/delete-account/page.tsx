import { APP_NAME, SUPPORT_EMAIL } from '@/lib/site';
import { DeletionForm, SignedInDelete } from './form';

export const metadata = { title: 'Delete your account' };

export default function DeleteAccount() {
  return (
    <main className="mx-auto max-w-3xl space-y-4 px-4 text-slate-300">
      <h1 className="text-3xl font-bold text-white">Delete your {APP_NAME} account</h1>
      <p>Deleting your account removes your profile, your cloud files and folders, the channels you own and their posts, your follows and blocks,
        your notification registrations (push tokens) and your measurement choices. It cannot be undone.</p>
      <h2 className="text-xl font-semibold text-white">In the app (fastest)</h2>
      <p>Open {APP_NAME}, tap the profile icon (top right) › Settings (gear) › <b>Delete Account</b> and confirm. Your account and files are removed immediately.</p>
      <h2 className="text-xl font-semibold text-white">On this page</h2>
      <p>Log in with your email and password, then delete the account here.</p>
      <SignedInDelete />
      <h2 className="text-xl font-semibold text-white">Cannot log in, or want to delete only some data?</h2>
      <p>Send this form. We reply within 7 days and finish the deletion within 30 days.</p>
      <DeletionForm />
      <h2 className="text-xl font-semibold text-white">Delete only some data</h2>
      <p>You can delete single files and folders in the Cloud tab, posts in your channel, or choose “Delete only some data” in the form and tell us what to remove.
        To stop notifications without deleting anything, turn them off in your phone&apos;s settings.</p>
      <h2 className="text-xl font-semibold text-white">What we keep</h2>
      <ul className="list-disc space-y-1 pl-6">
        <li>Payment records (plan, amount, date, order reference, transaction id/UTR) are kept for 8 years for Indian tax law, without your name or files.</li>
        <li>Reports you sent about other content may be kept for safety, without your account.</li>
        <li>Meta measurement events already delivered to Meta cannot be recalled by us; events not yet sent are no longer linked to you.</li>
        <li>Backups and hosting/security logs expire on their providers&apos; normal schedule.</li>
      </ul>
      <p>Questions: <a className="underline" href={`mailto:${SUPPORT_EMAIL}`}>{SUPPORT_EMAIL}</a></p>
    </main>
  );
}
