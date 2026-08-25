import 'package:flutter_test/flutter_test.dart';
import 'package:trycatch/src/collections/ring_buffer.dart';

void main() {
  group('RingBuffer', () {
    test('initial state is empty', () {
      final buffer = RingBuffer<int>(5);
      expect(buffer.length, 0);
      expect(buffer.capacity, 5);
      expect(buffer.isEmpty, isTrue);
      expect(buffer.isFull, isFalse);
    });

    test('pushes elements until capacity without overwriting', () {
      final buffer = RingBuffer<int>(3);
      buffer.push(10);
      buffer.push(20);

      expect(buffer.length, 2);
      expect(buffer[0], 20); // newest first
      expect(buffer[1], 10);
      expect(buffer.getChronological(0), 10); // oldest first
      expect(buffer.getChronological(1), 20);
    });

    test('overwrites oldest elements when full (O(1) circular wrap)', () {
      final buffer = RingBuffer<int>(3);
      buffer.push(1);
      buffer.push(2);
      buffer.push(3);
      expect(buffer.isFull, isTrue);

      // Overwrite 1
      buffer.push(4);
      expect(buffer.length, 3);
      expect(buffer[0], 4); // newest
      expect(buffer[1], 3);
      expect(buffer[2], 2); // oldest remaining
      expect(buffer.getChronological(0), 2);
      expect(buffer.getChronological(1), 3);
      expect(buffer.getChronological(2), 4);

      // Overwrite 2
      buffer.push(5);
      expect(buffer.toList(newestFirst: true), [5, 4, 3]);
      expect(buffer.toList(newestFirst: false), [3, 4, 5]);
    });

    test('implements Iterable correctly', () {
      final buffer = RingBuffer<String>(4);
      buffer.pushAll(['a', 'b', 'c', 'd', 'e']); // 'a' overwritten

      final iterated = buffer.map((s) => s.toUpperCase()).toList();
      expect(iterated, ['B', 'C', 'D', 'E']);
    });

    test('clears elements and resets state', () {
      final buffer = RingBuffer<int>(3);
      buffer.push(1);
      buffer.push(2);
      buffer.clear();

      expect(buffer.isEmpty, isTrue);
      expect(buffer.length, 0);

      buffer.push(42);
      expect(buffer.length, 1);
      expect(buffer[0], 42);
    });

    test('throws on out-of-bounds indexing', () {
      final buffer = RingBuffer<int>(3);
      buffer.push(1);

      expect(() => buffer[1], throwsRangeError);
      expect(() => buffer[-1], throwsRangeError);
      expect(() => buffer.getChronological(1), throwsRangeError);
    });
  });
}
