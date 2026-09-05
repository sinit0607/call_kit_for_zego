import '../../api/models/user_info.dart';

/// Manages the current user session
///
/// This is a simple session tracker that holds the current authenticated user.
/// It does NOT handle authentication itself - that's the main app's responsibility.
class SessionManager {
  UserInfo? _currentUser;

  /// Get the current authenticated user
  UserInfo? get currentUser => _currentUser;

  /// Check if a user is currently authenticated
  bool get isAuthenticated => _currentUser != null;

  /// Set the current user after login
  ///
  /// Call this after successful authentication in the main app.
  /// The package needs to know who the current user is to properly
  /// handle incoming calls and messages.
  Future<void> setCurrentUser(UserInfo user) async {
    _currentUser = user;
  }

  /// Clear the current user on logout
  ///
  /// Call this when the user logs out.
  /// This will clear the session but NOT end any active calls/chats.
  /// The main app should end calls/chats before logging out.
  Future<void> clearUser() async {
    _currentUser = null;
  }

  /// Dispose resources
  void dispose() {
    _currentUser = null;
  }
}
