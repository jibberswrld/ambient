import { ArrowUpRight, CircleUser } from 'lucide-react';
import { useEffect, useState } from 'react';
import type { AccountSummary, AmbientHost } from '../host/contract';
import { subscribeToHostEvents } from '../host/subscribe';
import { CapsuleButton } from '../design/controls';
import { EmptyState, SettingsPage } from './settingsShared';

/** Account: who is signed in, their plan, and how much of this month's allowance is left. Never any money. */
export function AccountPage(props: { host: AmbientHost }) {
  const { host } = props;
  const [accountSummary, setAccountSummary] = useState<AccountSummary | null>(null);

  useEffect(() => {
    let isCurrent = true;
    void host.invoke('get_account_summary', {}).then((loadedSummary) => {
      if (isCurrent) setAccountSummary(loadedSummary);
    });
    const stopListening = subscribeToHostEvents(host, {
      'ambient:account-summary': (updatedSummary) => setAccountSummary(updatedSummary),
    });
    return () => {
      isCurrent = false;
      stopListening();
    };
  }, [host]);

  return (
    <SettingsPage section="account">
      {accountSummary ? (
        <div className="settings-card account-card">
          <div className="account-identity">
            <span className="account-avatar" aria-hidden>
              {accountSummary.publikHandle ? accountSummary.publikHandle.slice(0, 1).toUpperCase() : 'P'}
            </span>
            <div className="account-names">
              {accountSummary.publikHandle ? <p className="account-handle">@{accountSummary.publikHandle}</p> : null}
              {accountSummary.planName ? <p className="account-plan">{accountSummary.planName} plan</p> : null}
            </div>
            <CapsuleButton
              title="Manage"
              icon={ArrowUpRight}
              prominence="secondary"
              surface="window"
              onClick={() => void host.invoke('open_url', { url: accountSummary.manageAccountUrl })}
            />
          </div>
          {accountSummary.usageRemainingFraction !== null ? (
            <>
              <div className="account-card-divider" aria-hidden />
              <UsageMeter remainingFraction={accountSummary.usageRemainingFraction} resetsOn={accountSummary.usageResetsOn} />
            </>
          ) : null}
        </div>
      ) : (
        <EmptyState icon={CircleUser} title="Account details" message="Your account details have not loaded yet. Open Settings again to retry." />
      )}
    </SettingsPage>
  );
}

const refillDateFormatter = new Intl.DateTimeFormat(undefined, { month: 'short', day: 'numeric' });

/** Usage as a percentage remaining, ember while there is plenty and red when it is nearly gone. */
function UsageMeter(props: { remainingFraction: number; resetsOn: string | null }) {
  const clampedFraction = Math.min(1, Math.max(0, props.remainingFraction));
  const remainingPercent = Math.round(clampedFraction * 100);
  const isNearlyGone = clampedFraction < 0.1;
  return (
    <div className="usage-meter">
      <div className="usage-meter-figures">
        <span className="usage-meter-percent">{remainingPercent}%</span>
        <span className="usage-meter-caption">left this month</span>
        <span className="usage-meter-spacer" />
        {props.resetsOn ? <span className="usage-meter-refill">Refills {refillDateFormatter.format(new Date(props.resetsOn))}</span> : null}
      </div>
      <div
        className="usage-meter-track"
        role="meter"
        aria-label="Allowance left this month"
        aria-valuemin={0}
        aria-valuemax={100}
        aria-valuenow={remainingPercent}
        aria-valuetext={`${remainingPercent}% left this month`}
      >
        {/* At least a sliver stays visible, so an empty allowance still reads as a meter rather than a blank line. */}
        <span className={`usage-meter-fill${isNearlyGone ? ' is-nearly-gone' : ''}`} style={{ width: `max(6px, ${clampedFraction * 100}%)` }} />
      </div>
    </div>
  );
}
