import 'package:flutter_test/flutter_test.dart';
import 'package:venera/utils/anime4k/upscale_status_tracker.dart';

void main() {
  final tracker = UpscaleStatusTracker.instance;

  setUp(tracker.clear);
  tearDown(tracker.clear);

  test('deduplicates requests and tracks cancellation separately', () {
    tracker.enqueue('job', 'Page 1', 'Real-CUGAN SE');
    tracker.enqueue('job', 'Page 1', 'Real-CUGAN SE');
    expect(tracker.activeCount, 1);
    expect(tracker.queuedCount, 1);

    tracker.finish(
      'job',
      success: false,
      cancelled: true,
      error: 'Chapter changed',
    );

    expect(tracker.activeCount, 0);
    expect(tracker.snapshot.single.value.status, UpscaleJobStatus.cancelled);
    expect(tracker.snapshot.single.value.error, 'Chapter changed');

    tracker.enqueue('job', 'Page 1', 'Real-CUGAN SE');
    expect(tracker.activeCount, 1);
    expect(tracker.snapshot.single.value.status, UpscaleJobStatus.queued);
  });

  test('retains retry actions for failed requests', () {
    var retried = false;
    tracker.enqueue('job', 'Page 2', 'Real-CUGAN Pro');
    tracker.setRetryAction('job', () => retried = true);
    tracker.finish('job', success: false, error: 'GPU unavailable');

    final job = tracker.snapshot.single.value;
    expect(job.status, UpscaleJobStatus.failed);
    expect(job.error, 'GPU unavailable');
    job.retryAction!();
    expect(retried, isTrue);
  });
}
