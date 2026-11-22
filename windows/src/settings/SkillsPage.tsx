import { FileText, FolderPlus, Package } from 'lucide-react';
import { useEffect, useState } from 'react';
import type { AmbientHost, SkillSummary } from '../host/contract';
import { subscribeToHostEvents } from '../host/subscribe';
import { CapsuleButton } from '../design/controls';
import { InlineError, ListCard, LoadingRows, SettingsPage, SettingsSectionLabel } from './settingsShared';

/** Skills: the person's own skills (installable from a folder, deletable) above the ones that ship with Ambient. */
export function SkillsPage(props: { host: AmbientHost }) {
  const { host } = props;
  const [skills, setSkills] = useState<SkillSummary[] | null>(null);
  const [errorMessage, setErrorMessage] = useState<string | null>(null);

  useEffect(() => {
    let isCurrent = true;
    void host.invoke('get_skills', {}).then((loadedSkills) => {
      if (isCurrent) setSkills(loadedSkills);
    });
    const stopListening = subscribeToHostEvents(host, {
      'ambient:skills': (updatedSkills) => setSkills(updatedSkills),
    });
    return () => {
      isCurrent = false;
      stopListening();
    };
  }, [host]);

  async function installSkillFromFolder() {
    setErrorMessage(null);
    try {
      // The host shows the folder picker; false only means the person cancelled it, which needs no message.
      await host.invoke('install_skill_from_folder', {});
    } catch {
      setErrorMessage('That folder could not be installed. Check it has a SKILL.md file.');
    }
  }

  async function deleteSkill(skill: SkillSummary) {
    setErrorMessage(null);
    try {
      await host.invoke('delete_skill', { skillName: skill.name });
    } catch {
      setErrorMessage(`Could not delete ${skill.name}.`);
    }
  }

  const personalSkills = skills?.filter((skill) => !skill.isBuiltIn) ?? [];
  const builtInSkills = skills?.filter((skill) => skill.isBuiltIn) ?? [];

  return (
    <SettingsPage
      section="skills"
      accessory={<CapsuleButton title="Install from folder" icon={FolderPlus} prominence="secondary" surface="window" onClick={() => void installSkillFromFolder()} />}
    >
      {errorMessage ? <InlineError message={errorMessage} /> : null}
      {skills === null ? (
        <LoadingRows rowCount={4} />
      ) : (
        <>
          <section className="settings-group">
            <SettingsSectionLabel>Yours</SettingsSectionLabel>
            {personalSkills.length === 0 ? (
              <p className="skills-empty-box">Install a folder that has a SKILL.md file in it, or ask Ambient to write one.</p>
            ) : (
              <ListCard label="Your skills">
                {personalSkills.map((skill) => (
                  <SkillRow key={skill.name} skill={skill} onDelete={() => void deleteSkill(skill)} />
                ))}
              </ListCard>
            )}
          </section>
          {builtInSkills.length > 0 ? (
            <section className="settings-group">
              <SettingsSectionLabel>Built in</SettingsSectionLabel>
              <ListCard label="Built-in skills">
                {builtInSkills.map((skill) => (
                  <SkillRow key={skill.name} skill={skill} onDelete={null} />
                ))}
              </ListCard>
            </section>
          ) : null}
        </>
      )}
    </SettingsPage>
  );
}

/** `onDelete` is null for built-in skills, which cannot be deleted. */
function SkillRow(props: { skill: SkillSummary; onDelete: (() => void) | null }) {
  const { skill } = props;
  const SkillIcon = skill.isBuiltIn ? Package : FileText;
  return (
    <div className="settings-list-row skill-row" role="listitem">
      <span className="settings-icon-tile" aria-hidden>
        <SkillIcon size={13} strokeWidth={2} />
      </span>
      <div className="settings-list-row-text">
        <p className="settings-list-row-title">{skill.name}</p>
        <p className="skill-description">{skill.description}</p>
      </div>
      {props.onDelete ? (
        <span className="reveal-on-row-hover skill-delete-slot">
          <CapsuleButton title="Delete" prominence="quiet" surface="window" isCompact onClick={props.onDelete} />
        </span>
      ) : null}
    </div>
  );
}
