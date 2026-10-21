import 'json_helpers.dart';

class TdUserIndex {
  TdUserIndex._();

  static final TdUserIndex shared = TdUserIndex._();

  static const _capacity = 4096;

  final Map<(int, int), Map<String, dynamic>> _users = {};

  Map<String, dynamic>? userFor(int slot, int userId) => _users[(slot, userId)];

  void observe(int slot, Map<String, dynamic> object) {
    switch (object.type) {
      case 'user':
        final userId = object.int64('id');
        if (userId == null || userId == 0) return;
        _users[(slot, userId)] = Map<String, dynamic>.unmodifiable(object);
        if (_users.length > _capacity) _users.remove(_users.keys.first);
      case 'updateUser':
        final user = object.obj('user');
        if (user != null) observe(slot, user);
    }
  }

  void clearSlot(int slot) {
    _users.removeWhere((key, _) => key.$1 == slot);
  }
}
