import 'package:path/path.dart';
import 'package:sqflite/sqflite.dart';

class DatabaseHelper {
  static final DatabaseHelper _instance = DatabaseHelper._internal();
  factory DatabaseHelper() => _instance;
  DatabaseHelper._internal();

  static Database? _database;

  Future<Database> get database async {
    if (_database != null) return _database!;
    _database = await _initDatabase();
    return _database!;
  }

  Future<Database> _initDatabase() async {
    String path = join(await getDatabasesPath(), 'chat_database.db');
    return await openDatabase(
      path,
      version: 1,
      onCreate: (db, version) async {
        await db.execute('''
          CREATE TABLE messages (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            studentId TEXT,
            text TEXT,
            isMe INTEGER,
            time TEXT,
            imagePath TEXT -- ستون جدید برای ذخیره مسیر تصویر
          )
        ''');
        await db.execute('''
          CREATE TABLE user_data (
            studentId TEXT PRIMARY KEY,
            messageCountPerMinute INTEGER,
            messageCountPerDay INTEGER,
            lastMessageTime TEXT,
            userScore INTEGER,
            lastResetTime TEXT,
            bio TEXT
          )
        ''');
      },
      onUpgrade: (db, oldVersion, newVersion) async {
        if (oldVersion < 2) {
          // اضافه کردن ستون imagePath به جدول messages برای دیتابیس‌های قدیمی
          await db.execute('ALTER TABLE messages ADD COLUMN imagePath TEXT');
        }
      },
    );
  }

  // ذخیره پیام
  Future<void> saveMessage(String studentId, Map<String, dynamic> message) async {
    final db = await database;
    await db.insert('messages', {
      'studentId': studentId,
      'text': message['text'],
      'isMe': message['isMe'] ? 1 : 0,
      'time': message['time'].toIso8601String(),
      'imagePath': message['imagePath'], // ذخیره imagePath (می‌تونه null باشه)
    });
  }

  // لود پیام‌ها
  Future<List<Map<String, dynamic>>> loadMessages(String studentId) async {
    final db = await database;
    final List<Map<String, dynamic>> maps = await db.query(
      'messages',
      where: 'studentId = ?',
      whereArgs: [studentId],
    );
    return maps.map((m) => {
      'id': m['id'].toString(),
      'text': m['text'],
      'isMe': m['isMe'] == 1,
      'time': DateTime.parse(m['time']),
      'imagePath': m['imagePath'], // لود imagePath (می‌تونه null باشه)
    }).toList();
  }

  // ذخیره یا آپدیت داده‌های کاربر (شامل بیوگرافی)
  Future<void> updateUserData(String studentId, Map<String, dynamic> data) async {
    final db = await database;
    await db.insert(
      'user_data',
      {
        'studentId': studentId,
        'messageCountPerMinute': data['messageCountPerMinute'],
        'messageCountPerDay': data['messageCountPerDay'],
        'lastMessageTime': data['lastMessageTime'],
        'userScore': data['userScore'],
        'lastResetTime': data['lastResetTime'],
        'bio': data['bio'],
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<Map<String, dynamic>> loadUserData(String studentId) async {
    final db = await database;
    final List<Map<String, dynamic>> maps = await db.query(
      'user_data',
      where: 'studentId = ?',
      whereArgs: [studentId],
    );
    if (maps.isNotEmpty) {
      return {
        'messageCountPerMinute': maps.first['messageCountPerMinute'] ?? 0,
        'messageCountPerDay': maps.first['messageCountPerDay'] ?? 0,
        'lastMessageTime': maps.first['lastMessageTime'],
        'userScore': maps.first['userScore'] ?? 0,
        'lastResetTime': maps.first['lastResetTime'],
        'bio': maps.first['bio'] ?? '',
      };
    }
    return {
      'messageCountPerMinute': 0,
      'messageCountPerDay': 0,
      'lastMessageTime': null,
      'userScore': 0,
      'lastResetTime': null,
      'bio': '',
    };
  }

  Future<void> resetDailyMessageCount(String studentId) async {
    final db = await database;
    final userData = await loadUserData(studentId);
    DateTime now = DateTime.now();
    DateTime? lastResetTime = userData['lastResetTime'] != null
        ? DateTime.parse(userData['lastResetTime'])
        : null;
    if (lastResetTime == null || now.difference(lastResetTime).inDays >= 1) {
      await db.update(
        'user_data',
        {
          'messageCountPerDay': 0,
          'lastResetTime': now.toIso8601String(),
        },
        where: 'studentId = ?',
        whereArgs: [studentId],
      );
    }
  }

  Future<void> deleteMessage(String studentId, String messageId) async {
    final db = await database;
    await db.delete(
      'messages',
      where: 'studentId = ? AND id = ?',
      whereArgs: [studentId, messageId],
    );
  }

  Future<void> clearMessages(String studentId) async {
    final db = await database;
    await db.delete('messages', where: 'studentId = ?', whereArgs: [studentId]);
  }
}