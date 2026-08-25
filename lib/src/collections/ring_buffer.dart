/// A fixed-capacity circular ring buffer with zero allocations during runtime.
///
/// Designed for high-frequency telemetry caching without causing GC stutter
/// or memory growth over hours of continuous operation.
///
/// Provides $O(1)$ push, $O(1)$ indexed reads, and implements [Iterable].
class RingBuffer<T> extends Iterable<T> {
  final int capacity;
  final List<T?> _buffer;
  int _head = 0; // Points to the next write slot
  int _length = 0;

  /// Creates a [RingBuffer] with a pre-allocated fixed [capacity].
  RingBuffer(this.capacity)
    : assert(capacity > 0, 'Capacity must be greater than zero.'),
      _buffer = List<T?>.filled(capacity, null);

  /// Current number of stored elements (0 <= [length] <= [capacity]).
  @override
  int get length => _length;

  /// Whether the buffer has reached maximum capacity and will overwrite oldest entries.
  bool get isFull => _length == capacity;

  @override
  bool get isEmpty => _length == 0;

  @override
  bool get isNotEmpty => _length > 0;

  /// Appends [item] to the buffer.
  ///
  /// If the buffer is full, the oldest element is overwritten in $O(1)$ time
  /// without reallocating the underlying storage.
  void push(T item) {
    _buffer[_head] = item;
    _head = (_head + 1) % capacity;
    if (_length < capacity) {
      _length++;
    }
  }

  /// Appends all elements from [items] into the buffer in order.
  void pushAll(Iterable<T> items) {
    for (final item in items) {
      push(item);
    }
  }

  /// Returns the element at [index] relative to the newest element:
  /// - `index = 0`: newest element (most recently pushed)
  /// - `index = length - 1`: oldest element
  ///
  /// Throws [RangeError] if [index] is out of bounds.
  T operator [](int index) {
    RangeError.checkValidIndex(index, this, 'index', _length);
    // Calculate index from the newest entry backwards
    final realIndex = (_head - 1 - index + capacity) % capacity;
    return _buffer[realIndex] as T;
  }

  /// Returns the element at [index] in chronological order:
  /// - `index = 0`: oldest element
  /// - `index = length - 1`: newest element
  T getChronological(int index) {
    RangeError.checkValidIndex(index, this, 'index', _length);
    final start = (_head - _length + capacity) % capacity;
    final realIndex = (start + index) % capacity;
    return _buffer[realIndex] as T;
  }

  /// Clears all stored elements without reallocating the underlying storage array.
  void clear() {
    _buffer.fillRange(0, capacity, null);
    _head = 0;
    _length = 0;
  }

  /// Exports stored elements to a standard [List].
  ///
  /// If [newestFirst] is true, index 0 will be the most recent packet.
  /// If false, elements are returned in chronological order (oldest to newest).
  @override
  List<T> toList({bool growable = true, bool newestFirst = false}) {
    final list = List<T>.generate(
      _length,
      (i) => newestFirst ? this[i] : getChronological(i),
      growable: growable,
    );
    return list;
  }

  @override
  Iterator<T> get iterator => _RingBufferIterator<T>(this);
}

class _RingBufferIterator<T> implements Iterator<T> {
  final RingBuffer<T> _buffer;
  int _index = -1;

  _RingBufferIterator(this._buffer);

  @override
  T get current {
    if (_index < 0 || _index >= _buffer.length) {
      throw StateError('No current element');
    }

    return _buffer.getChronological(_index);
  }

  @override
  bool moveNext() {
    if (_index + 1 < _buffer.length) {
      _index++;
      return true;
    }
    return false;
  }
}
