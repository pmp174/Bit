import { useAppSelector } from '@renderer/hooks/useAppSelector';
import { ProgressBar } from '../ProgressComponents';

export function DownloadsPage() {
  const { main } = useAppSelector((state) => state);
  const downloaderState = main.downloaderState;
  const tasks = Object.values(downloaderState.tasks);

  return (
    <div className='downloads-page'>
      <div className='downloads-page__upper'>
        <div>
          {`Task completion: ${tasks.filter(t => t.status !== 'waiting' && t.status !== 'in_progress').length} /  ${tasks.length}`}
        </div>
        <div>
          {`Failures: ${tasks.filter(t => t.status === 'failure').length}`}
        </div>
      </div>
      <div className='downloads-page__workers'>
        { downloaderState.workers.map((worker, idx) => {
          const progressPercent = ((worker.step - 1) / worker.totalSteps) + worker.stepProgress;
          const isDone = worker.text === 'Done';
          return (
            <div className='downloads-page__workers-worker'>
              <ProgressBar
                progressData={{
                  key: `downloads-worder-${idx}`,
                  usePercentDone: true,
                  percentDone: progressPercent,
                  itemCount: 0,
                  totalItems: 0,
                  isDone,
                  text: `Downloading game...`,
                  secondaryText: worker.text,
                }} />
            </div>
          );
        })}
      </div>
    </div>
  )
}