import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/task_provider.dart';
import '../config/gemini_config.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import '../models/task.dart';
import '../models/subtask.dart';
import 'package:uuid/uuid.dart';
import 'main_screen.dart';
import 'focus_screen.dart';
import 'package:confetti/confetti.dart';
import 'dart:math';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;
import 'package:permission_handler/permission_handler.dart';

class TaskListScreen extends StatefulWidget {
  const TaskListScreen({super.key});

  @override
  State<TaskListScreen> createState() => _TaskListScreenState();
}

class _TaskListScreenState extends State<TaskListScreen> {
  late ConfettiController _confettiController;
  bool _isLoading = false;

  // Speech to text variables
  final stt.SpeechToText _speech = stt.SpeechToText();
  bool _isListening = false;
  String _listeningStatus = '';

  @override
  void initState() {
    super.initState();
    _confettiController =
        ConfettiController(duration: const Duration(seconds: 2));
    _initSpeech();
  }

  // Initialize speech recognition
  Future<void> _initSpeech() async {
    bool available = await _speech.initialize(
      onStatus: (status) {
        setState(() {
          _listeningStatus = status;
          if (status == 'done' || status == 'notListening') {
            _isListening = false;
          }
        });
        debugPrint('Speech status: $status');
      },
      onError: (error) {
        setState(() {
          _isListening = false;
        });
        debugPrint('Speech error: $error');
      },
    );
    debugPrint('Speech recognition available: $available');
  }

  // Request microphone permission
  Future<bool> _requestMicPermission() async {
    var status = await Permission.microphone.status;
    if (!status.isGranted) {
      status = await Permission.microphone.request();
    }
    return status.isGranted;
  }

  @override
  void dispose() {
    _confettiController.dispose();
    _speech.stop();
    super.dispose();
  }

  void _showCompletionPopup(Task task) {
    _confettiController.play();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.star, color: Colors.amber),
            const SizedBox(width: 8),
            Text(
              'Well done! +${task.xpEarned} XP',
              style: const TextStyle(color: Colors.white),
            ),
          ],
        ),
        backgroundColor: Colors.deepPurple.shade400,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        margin: const EdgeInsets.all(8),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  Future<(List<String>, TaskDifficulty, int)> _getAIBreakdown(Task task) async {
    try {
      debugPrint('Requesting AI breakdown for task: ${task.title}');
      final response = await http.post(
        Uri.parse('${GeminiConfig.endpoint}?key=${GeminiConfig.apiKey}'),
        headers: {
          'Content-Type': 'application/json',
        },
        body: jsonEncode({
          'contents': [
            {
              'parts': [
                {
                  'text':
                      '''Analyze this task and provide a response in this exact format:

DIFFICULTY: [easy/medium/hard/epic]
XP: [number between 50-400 based on complexity]
STEPS:
1. [First step]
2. [Second step]
3. [Third step]

Task to analyze: ${task.title}'''
                }
              ]
            }
          ],
          'generationConfig': {
            'temperature': 0.7,
            'maxOutputTokens': 150,
          },
        }),
      );

      if (response.statusCode == 429) {
        debugPrint('Rate limited by Gemini AI');
        return (<String>[], TaskDifficulty.medium, 100);
      }

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final content =
            data['candidates'][0]['content']['parts'][0]['text'] as String;

        debugPrint('Raw AI response: $content');

        final difficultyMatch =
            RegExp(r'DIFFICULTY:\s*(\w+)').firstMatch(content);
        TaskDifficulty difficulty = TaskDifficulty.medium;

        if (difficultyMatch != null) {
          final difficultyStr = difficultyMatch.group(1)?.toLowerCase() ?? '';
          debugPrint('Extracted difficulty: $difficultyStr');
          switch (difficultyStr) {
            case 'easy':
              difficulty = TaskDifficulty.easy;
              break;
            case 'hard':
              difficulty = TaskDifficulty.hard;
              break;
            case 'epic':
              difficulty = TaskDifficulty.epic;
              break;
          }
        } else {
          debugPrint(
              'No difficulty found in AI response, using default: medium');
        }

        final xpMatch = RegExp(r'XP:\s*(\d+)').firstMatch(content);
        int xp = 100; // Default medium task XP

        if (xpMatch != null) {
          final xpString = xpMatch.group(1) ?? '100';
          debugPrint('Extracted XP string from AI response: "$xpString"');

          try {
            xp = int.parse(xpString);
            debugPrint('Successfully parsed XP from AI response: $xp');

            // Ensure XP is within reasonable bounds
            if (xp < 50) {
              debugPrint('XP too low, adjusting to minimum: 50');
              xp = 50;
            } else if (xp > 400) {
              debugPrint('XP too high, adjusting to maximum: 400');
              xp = 400;
            }
          } catch (e) {
            debugPrint('Error parsing XP value: $e, using default: $xp');
          }
        } else {
          // If no XP is specified, set based on difficulty
          debugPrint('No XP found in AI response, setting based on difficulty');
          switch (difficulty) {
            case TaskDifficulty.easy:
              xp = 50;
              break;
            case TaskDifficulty.medium:
              xp = 100;
              break;
            case TaskDifficulty.hard:
              xp = 200;
              break;
            case TaskDifficulty.epic:
              xp = 400;
              break;
          }
          debugPrint('Set XP based on difficulty: $xp');
        }

        final steps = RegExp(r'STEPS:\s*((?:\d+\.\s*[^\n]+\n?)+)')
                .firstMatch(content)
                ?.group(1)
                ?.split('\n')
                .where((step) => step.trim().isNotEmpty)
                .map((step) {
                  final cleanStep =
                      step.replaceAll(RegExp(r'^\d+\.\s*'), '').trim();
                  return cleanStep;
                })
                .where((step) => step.isNotEmpty)
                .take(3)
                .expand((step) {
                  // If step is very long (over 100 chars), try to break it into logical parts
                  if (step.length > 100) {
                    debugPrint('Splitting long subtask: ${step.length} chars');

                    // Try to split by sentence boundaries first
                    final sentences = step.split(RegExp(r'(?<=[.!?])\s+'));

                    // If we have multiple sentences, return them as separate steps
                    if (sentences.length > 1) {
                      debugPrint(
                          'Split into ${sentences.length} sentence-based subtasks');
                      return sentences;
                    }

                    // If it's one long sentence, try to split by clauses/phrases
                    final clauses = step.split(RegExp(r'(?<=[,;:])\s+'));
                    if (clauses.length > 1) {
                      // Group clauses to avoid too many tiny subtasks
                      final List<String> groupedClauses = [];
                      String currentGroup = '';

                      for (final clause in clauses) {
                        if (currentGroup.isEmpty) {
                          currentGroup = clause;
                        } else if ((currentGroup + clause).length < 100) {
                          currentGroup += ', ' + clause;
                        } else {
                          groupedClauses.add(currentGroup);
                          currentGroup = clause;
                        }
                      }

                      if (currentGroup.isNotEmpty) {
                        groupedClauses.add(currentGroup);
                      }

                      debugPrint(
                          'Split into ${groupedClauses.length} clause-based subtasks');
                      return groupedClauses;
                    }

                    // If still too long and no natural breaks, do a simple split
                    if (step.length > 100) {
                      final words = step.split(' ');
                      final List<String> chunks = [];
                      String currentChunk = '';

                      for (final word in words) {
                        if (currentChunk.isEmpty) {
                          currentChunk = word;
                        } else if ((currentChunk + ' ' + word).length < 80) {
                          currentChunk += ' ' + word;
                        } else {
                          chunks.add(currentChunk);
                          currentChunk = word;
                        }
                      }

                      if (currentChunk.isNotEmpty) {
                        chunks.add(currentChunk);
                      }

                      debugPrint(
                          'Split into ${chunks.length} word-based subtasks');
                      return chunks;
                    }
                  }

                  // If not too long or couldn't be split effectively, return as is
                  return [step];
                })
                .toList() ??
            [];

        if (steps.isEmpty) {
          debugPrint('No steps found in AI response');
          // Use full task title without truncation
          return ([task.title], difficulty, xp);
        }

        debugPrint('AI breakdown generated ${steps.length} subtasks');
        for (var step in steps) {
          debugPrint('Subtask: $step');
        }

        debugPrint(
            'Final AI breakdown: Difficulty=$difficulty, XP=$xp, Steps=${steps.length}');
        return (steps, difficulty, xp);
      }

      debugPrint('Gemini AI error: ${response.statusCode} - ${response.body}');
      return (<String>[], TaskDifficulty.medium, 100);
    } catch (e) {
      debugPrint('Error getting AI breakdown: $e');
      return (<String>[], TaskDifficulty.medium, 100);
    }
  }

  Future<void> _showAddTaskDialog() async {
    final titleController = TextEditingController();
    bool useAIBreakdown = false;
    bool isUrgent = false;

    await showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setState) => AlertDialog(
          title: const Text('Add New Task'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: titleController,
                        decoration: const InputDecoration(
                          labelText: 'Task Title',
                          border: OutlineInputBorder(),
                        ),
                        maxLength: 50,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Container(
                      decoration: BoxDecoration(
                        color: _isListening
                            ? Colors.amber.shade300
                            : Colors.deepPurple.shade100,
                        borderRadius: BorderRadius.circular(50),
                      ),
                      child: IconButton(
                        onPressed: () async {
                          bool hasPermission = await _requestMicPermission();
                          if (!hasPermission) {
                            if (context.mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(
                                  content:
                                      Text('Microphone permission required!'),
                                ),
                              );
                            }
                            return;
                          }

                          if (!_isListening) {
                            var available = await _speech.initialize();
                            if (available) {
                              setState(() {
                                _isListening = true;
                              });
                              _speech.listen(
                                onResult: (result) {
                                  setState(() {
                                    titleController.text =
                                        result.recognizedWords;
                                  });
                                },
                                listenFor: const Duration(seconds: 15),
                                pauseFor: const Duration(seconds: 3),
                                partialResults: true,
                                cancelOnError: true,
                                listenMode: stt.ListenMode.confirmation,
                              );
                            }
                          } else {
                            setState(() {
                              _isListening = false;
                            });
                            _speech.stop();
                          }
                        },
                        icon: Icon(
                          _isListening ? Icons.mic : Icons.mic_none,
                          color: _isListening
                              ? Colors.deepPurple.shade900
                              : Colors.deepPurple.shade400,
                        ),
                        tooltip: 'Speak task title',
                      ),
                    ),
                  ],
                ),
                if (_isListening) ...[
                  const SizedBox(height: 8),
                  Text(
                    'Listening...',
                    style: TextStyle(
                      color: Colors.deepPurple.shade400,
                      fontStyle: FontStyle.italic,
                    ),
                  ),
                ],
                const SizedBox(height: 16),
                CheckboxListTile(
                  title: const Text('Use AI to analyze task'),
                  subtitle:
                      const Text('Get difficulty level, XP, and subtasks'),
                  value: useAIBreakdown,
                  onChanged: (value) {
                    setState(() {
                      useAIBreakdown = value ?? false;
                    });
                  },
                ),
                CheckboxListTile(
                  title: const Text('High Priority'),
                  subtitle: const Text('Mark this task as high priority'),
                  value: isUrgent,
                  onChanged: (value) {
                    setState(() {
                      isUrgent = value ?? false;
                    });
                  },
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () {
                _speech.stop();
                Navigator.pop(context);
              },
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              onPressed: () async {
                _speech.stop();
                if (titleController.text.isNotEmpty) {
                  setState(() {
                    _isLoading = true;
                  });

                  if (useAIBreakdown) {
                    // Create a temporary task to get the AI breakdown
                    final tempTask = Task(
                      id: const Uuid().v4(),
                      userId: context.read<TaskProvider>().currentUserId ?? '',
                      title: titleController.text,
                      description: '',
                      isCompleted: false,
                      subtasks: const [],
                      xpEarned: 0,
                      completedAt: null,
                      createdAt: DateTime.now(),
                      estimatedDuration: null,
                      isRecurring: false,
                      category: null,
                      difficulty: TaskDifficulty.medium,
                      isUrgent: isUrgent,
                    );

                    // Get the AI breakdown
                    final (subtasks, difficulty, xp) =
                        await _getAIBreakdown(tempTask);

                    // Create the final task with AI results
                    final task = Task(
                      id: const Uuid().v4(),
                      userId: context.read<TaskProvider>().currentUserId ?? '',
                      title: titleController.text,
                      description: '',
                      isCompleted: false,
                      subtasks: subtasks
                          .map((title) => Subtask(
                                id: const Uuid().v4(),
                                title: title,
                                isCompleted: false,
                              ))
                          .toList(),
                      xpEarned: xp,
                      completedAt: null,
                      createdAt: DateTime.now(),
                      estimatedDuration: null,
                      isRecurring: false,
                      category: null,
                      difficulty: difficulty,
                      isUrgent: isUrgent,
                    );

                    // Add the task with all properties already set
                    context.read<TaskProvider>().addTask(task);
                  } else {
                    // Create and add a regular task without AI breakdown
                    final task = Task(
                      id: const Uuid().v4(),
                      userId: context.read<TaskProvider>().currentUserId ?? '',
                      title: titleController.text,
                      description: '',
                      isCompleted: false,
                      subtasks: const [],
                      xpEarned: 50,
                      completedAt: null,
                      createdAt: DateTime.now(),
                      estimatedDuration: null,
                      isRecurring: false,
                      category: null,
                      difficulty: TaskDifficulty.medium,
                      isUrgent: isUrgent,
                    );
                    context.read<TaskProvider>().addTask(task);
                  }

                  setState(() {
                    _isLoading = false;
                  });
                  Navigator.pop(context);
                }
              },
              child: _isLoading
                  ? Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            valueColor:
                                AlwaysStoppedAnimation<Color>(Colors.white),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Icon(
                          Icons.emoji_nature,
                          size: 20,
                          color: Colors.amber[300],
                        ),
                      ],
                    )
                  : const Text('Add Task'),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return NavigationWrapper(
      initialIndex: 0,
      child: Stack(
        children: [
          Scaffold(
            appBar: AppBar(
              title: const Text('Tasks'),
              backgroundColor: Colors.deepPurple,
              foregroundColor: Colors.white,
              elevation: 0,
              actions: [
                IconButton(
                  icon: const Icon(Icons.settings),
                  onPressed: () {
                    // TODO: Navigate to settings screen
                  },
                ),
              ],
            ),
            body: Container(
              decoration: const BoxDecoration(
                color: Colors.deepPurple,
              ),
              child: Consumer<TaskProvider>(
                builder: (context, taskProvider, child) {
                  debugPrint(
                      'TaskListScreen: Received ${taskProvider.tasks.length} tasks from TaskProvider');
                  if (taskProvider.tasks.isEmpty) {
                    debugPrint('TaskListScreen: No tasks to display');
                    return Center(
                      child: Text(
                        'No tasks yet. Add one to get started!',
                        style: TextStyle(
                          color: Colors.white.withOpacity(0.8),
                          fontSize: 16,
                        ),
                      ),
                    );
                  }

                  return ListView.builder(
                    padding: const EdgeInsets.all(16),
                    itemCount: taskProvider.tasks.length,
                    itemBuilder: (context, index) {
                      final task = taskProvider.tasks[index];
                      return _buildTaskItem(task);
                    },
                  );
                },
              ),
            ),
            floatingActionButton: FloatingActionButton(
              onPressed: _showAddTaskDialog,
              backgroundColor: Colors.amber[300],
              child: const Icon(Icons.add, color: Colors.black),
            ),
          ),
          Align(
            alignment: Alignment.topCenter,
            child: ConfettiWidget(
              confettiController: _confettiController,
              blastDirection: pi / 2,
              maxBlastForce: 5,
              minBlastForce: 2,
              emissionFrequency: 0.05,
              numberOfParticles: 20,
              gravity: 0.1,
              shouldLoop: false,
              colors: const [
                Colors.amber,
                Colors.purple,
                Colors.blue,
                Colors.pink,
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTaskItem(Task task) {
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      color: Colors.deepPurple.shade50,
      child: InkWell(
        onTap: () {
          Navigator.push(
            context,
            MaterialPageRoute(
              builder: (context) => FocusScreen(task: task),
            ),
          ).then((completed) {
            if (completed == true) {
              setState(() {}); // Force UI update
              final taskProvider = context.read<TaskProvider>();
              final updatedTask =
                  taskProvider.tasks.firstWhere((t) => t.id == task.id);
              if (updatedTask.isCompleted) {
                _showCompletionPopup(updatedTask);
              }
            }
          });
        },
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(
                    _getDifficultyIcon(task.difficulty),
                    size: 16,
                    color: _getDifficultyColor(task.difficulty),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    task.difficulty.name.toUpperCase(),
                    style: TextStyle(
                      color: _getDifficultyColor(task.difficulty),
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(
                      color: Colors.amber[100],
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.star, size: 16, color: Colors.amber[700]),
                        const SizedBox(width: 4),
                        Text(
                          '${task.xpEarned} XP',
                          style: TextStyle(
                            color: Colors.amber[900],
                            fontSize: 12,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (task.isUrgent) ...[
                    const SizedBox(width: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 4),
                      decoration: BoxDecoration(
                        color: Colors.amber[100],
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.warning_amber,
                              size: 16, color: Colors.amber[700]),
                          const SizedBox(width: 4),
                          Text(
                            'HIGH PRIORITY',
                            style: TextStyle(
                              color: Colors.amber[900],
                              fontSize: 12,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ],
              ),
              const SizedBox(height: 8),
              Text(
                task.title,
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                  color: Colors.deepPurple.shade900,
                  decoration:
                      task.isCompleted ? TextDecoration.lineThrough : null,
                  decorationColor: Colors.deepPurple.shade900,
                  decorationThickness: 2,
                ),
              ),
              const SizedBox(height: 16),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  _buildActionButton(
                    onPressed: () {
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (context) => FocusScreen(task: task),
                        ),
                      ).then((completed) {
                        if (completed == true) {
                          setState(() {}); // Force UI update
                          final taskProvider = context.read<TaskProvider>();
                          final updatedTask = taskProvider.tasks
                              .firstWhere((t) => t.id == task.id);
                          if (updatedTask.isCompleted) {
                            _showCompletionPopup(updatedTask);
                          }
                        }
                      });
                    },
                    icon: Icons.emoji_nature,
                    label: 'Focus',
                    color: Colors.deepPurple.shade900,
                    textColor: Colors.amber[300]!,
                  ),
                  const SizedBox(width: 8),
                  _buildActionButton(
                    onPressed: () {
                      context
                          .read<TaskProvider>()
                          .toggleTaskCompletion(task.id, !task.isCompleted);
                      if (!task.isCompleted) {
                        _showCompletionPopup(task);
                      }
                      setState(() {}); // Force UI update after completion
                    },
                    icon: Icons.check_circle_outline,
                    label: 'Quick Complete',
                    color: Colors.green.shade600,
                  ),
                  const SizedBox(width: 8),
                  IconButton(
                    onPressed: () {
                      showDialog(
                        context: context,
                        builder: (context) => AlertDialog(
                          title: const Text('Delete Task'),
                          content: const Text(
                              'Are you sure you want to delete this task?'),
                          actions: [
                            TextButton(
                              onPressed: () => Navigator.pop(context),
                              child: const Text('Cancel'),
                            ),
                            TextButton(
                              onPressed: () async {
                                Navigator.pop(context);
                                try {
                                  await context
                                      .read<TaskProvider>()
                                      .deleteTaskFromFirebase(task.id);
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    const SnackBar(
                                      content:
                                          Text('Task deleted successfully'),
                                      duration: Duration(seconds: 2),
                                    ),
                                  );
                                } catch (e) {
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    SnackBar(
                                      content: Text('Error deleting task: $e'),
                                      duration: const Duration(seconds: 2),
                                    ),
                                  );
                                }
                              },
                              child: const Text('Delete'),
                            ),
                          ],
                        ),
                      );
                    },
                    icon: const Icon(Icons.delete_outline),
                    color: Colors.red.shade400,
                    tooltip: 'Delete Task',
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(),
                    iconSize: 20,
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildActionButton({
    required VoidCallback onPressed,
    required IconData icon,
    required String label,
    required Color color,
    Color? textColor,
  }) {
    return ElevatedButton.icon(
      onPressed: onPressed,
      icon: Icon(icon, size: 18, color: textColor),
      label: Text(
        label,
        style: TextStyle(
          fontSize: 12,
          color: textColor,
        ),
      ),
      style: ElevatedButton.styleFrom(
        backgroundColor: color,
        foregroundColor: textColor ?? Colors.white,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(8),
        ),
        elevation: 2,
      ),
    );
  }

  IconData _getDifficultyIcon(TaskDifficulty difficulty) {
    switch (difficulty) {
      case TaskDifficulty.easy:
        return Icons.sentiment_satisfied;
      case TaskDifficulty.medium:
        return Icons.sentiment_neutral;
      case TaskDifficulty.hard:
        return Icons.sentiment_dissatisfied;
      case TaskDifficulty.epic:
        return Icons.emoji_events;
    }
  }

  Color _getDifficultyColor(TaskDifficulty difficulty) {
    switch (difficulty) {
      case TaskDifficulty.easy:
        return Colors.green;
      case TaskDifficulty.medium:
        return Colors.orange;
      case TaskDifficulty.hard:
        return Colors.red;
      case TaskDifficulty.epic:
        return Colors.purple;
    }
  }
}
