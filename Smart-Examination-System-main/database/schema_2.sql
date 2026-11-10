
-- Smart Examination & Proctoring Management System

CREATE DATABASE IF NOT EXISTS smart_exam;
USE smart_exam;

-- SECTION 1: TABLE DEFINITIONS

-- 1. ROLES
CREATE TABLE IF NOT EXISTS ROLES(
    role_id   INT PRIMARY KEY AUTO_INCREMENT,
    role_name VARCHAR(50) NOT NULL UNIQUE
);

-- 2. USERS
CREATE TABLE IF NOT EXISTS USERS(
    user_id  INT PRIMARY KEY AUTO_INCREMENT,
    name     VARCHAR(100) NOT NULL,
    email    VARCHAR(100) UNIQUE NOT NULL,
    password VARCHAR(255) NOT NULL,
    role_id  INT,
    FOREIGN KEY (role_id) REFERENCES ROLES(role_id) ON DELETE SET NULL
);

-- 3. EXAMS
CREATE TABLE IF NOT EXISTS EXAMS(
    exam_id          INT PRIMARY KEY AUTO_INCREMENT,
    subject          VARCHAR(100) NOT NULL,
    exam_date        DATETIME NOT NULL,
    duration_minutes INT NOT NULL,
    total_marks      INT NOT NULL,
    negative_marking DECIMAL(5,2) DEFAULT 0.0 CHECK (negative_marking >= 0)
);

-- 4. QUESTIONS
CREATE TABLE IF NOT EXISTS QUESTIONS(
    question_id   INT PRIMARY KEY AUTO_INCREMENT,
    exam_id       INT,
    question_text TEXT NOT NULL,
    question_type VARCHAR(50) NOT NULL DEFAULT 'MCQ',
    difficulty    VARCHAR(50) CHECK (difficulty IN ('EASY', 'MEDIUM', 'HARD')),
    topic         VARCHAR(100),
    marks         INT NOT NULL CHECK (marks > 0),
    FOREIGN KEY (exam_id) REFERENCES EXAMS(exam_id) ON DELETE CASCADE
);

-- 5. OPTIONS
CREATE TABLE IF NOT EXISTS OPTIONS(
    option_id   INT PRIMARY KEY AUTO_INCREMENT,
    question_id INT,
    option_text TEXT NOT NULL,
    is_correct  BOOLEAN DEFAULT FALSE,
    FOREIGN KEY (question_id) REFERENCES QUESTIONS(question_id) ON DELETE CASCADE
);

-- 6. STUDENT_EXAM
CREATE TABLE IF NOT EXISTS STUDENT_EXAM(
    attempt_id INT PRIMARY KEY AUTO_INCREMENT,
    user_id    INT,
    exam_id    INT,
    start_time DATETIME,
    end_time   DATETIME,
    status     VARCHAR(50) DEFAULT 'IN_PROGRESS'
                   CHECK (status IN ('IN_PROGRESS', 'COMPLETED', 'ABORTED')),
    UNIQUE KEY user_exam_unique (user_id, exam_id),
    FOREIGN KEY (user_id) REFERENCES USERS(user_id)  ON DELETE CASCADE,
    FOREIGN KEY (exam_id) REFERENCES EXAMS(exam_id)  ON DELETE CASCADE
);

-- 7. STUDENT_RESPONSE
CREATE TABLE IF NOT EXISTS STUDENT_RESPONSE(
    response_id        INT PRIMARY KEY AUTO_INCREMENT,
    attempt_id         INT,
    question_id        INT,
    selected_option_id INT,
    response_time      DATETIME DEFAULT CURRENT_TIMESTAMP,
    FOREIGN KEY (attempt_id)         REFERENCES STUDENT_EXAM(attempt_id) ON DELETE CASCADE,
    FOREIGN KEY (question_id)        REFERENCES QUESTIONS(question_id)   ON DELETE CASCADE,
    FOREIGN KEY (selected_option_id) REFERENCES OPTIONS(option_id)       ON DELETE SET NULL
);

-- 8. PROCTORING_LOG
CREATE TABLE IF NOT EXISTS PROCTORING_LOG(
    log_id           INT PRIMARY KEY AUTO_INCREMENT,
    attempt_id       INT,
    login_time       DATETIME DEFAULT CURRENT_TIMESTAMP,
    logout_time      DATETIME,
    tab_switch_count INT DEFAULT 0 CHECK (tab_switch_count >= 0),
    suspicious_flag  BOOLEAN DEFAULT FALSE,
    FOREIGN KEY (attempt_id) REFERENCES STUDENT_EXAM(attempt_id) ON DELETE CASCADE
);

-- 9. RESULTS
CREATE TABLE IF NOT EXISTS RESULTS(
    result_id     INT PRIMARY KEY AUTO_INCREMENT,
    attempt_id    INT,
    score         DECIMAL(10,2),
    student_rank  INT,
    result_status VARCHAR(50),
    FOREIGN KEY (attempt_id) REFERENCES STUDENT_EXAM(attempt_id) ON DELETE CASCADE
);


-- SECTION 2: STORED FUNCTIONS


-- FUNCTION: ExamPassRate
-- Returns the pass percentage for a given exam.
-- Usage : SELECT ExamPassRate(1);

DELIMITER //
DROP FUNCTION IF EXISTS ExamPassRate //
CREATE FUNCTION ExamPassRate(p_exam_id INT)
RETURNS DECIMAL(5,2)
DETERMINISTIC
READS SQL DATA
BEGIN
    DECLARE v_total  INT DEFAULT 0;
    DECLARE v_passed INT DEFAULT 0;

    SELECT COUNT(*)
    INTO   v_total
    FROM   RESULTS r
    JOIN   STUDENT_EXAM se ON r.attempt_id = se.attempt_id
    WHERE  se.exam_id = p_exam_id;

    SELECT COUNT(*)
    INTO   v_passed
    FROM   RESULTS r
    JOIN   STUDENT_EXAM se ON r.attempt_id = se.attempt_id
    WHERE  se.exam_id     = p_exam_id
      AND  r.result_status = 'PASS';

    IF v_total = 0 THEN
        RETURN 0.00;
    END IF;

    RETURN ROUND((v_passed / v_total) * 100, 2);
END //
DELIMITER ;

-- SECTION 3: STORED PROCEDURES


-- PROCEDURE: CalculateTotalScore  (original, kept intact)
-- Calculates score for one attempt with negative marking.
-- Usage : CALL CalculateTotalScore(1, @score); SELECT @score;

DELIMITER //
DROP PROCEDURE IF EXISTS CalculateTotalScore //
CREATE PROCEDURE CalculateTotalScore(
    IN  p_attempt_id   INT,
    OUT p_total_score  DECIMAL(10,2)
)
BEGIN
    DECLARE v_correct_score   DECIMAL(10,2) DEFAULT 0;
    DECLARE v_negative_score  DECIMAL(10,2) DEFAULT 0;
    DECLARE v_negative_marking DECIMAL(5,2) DEFAULT 0;
    DECLARE v_exam_id         INT;

    -- Get exam id and negative marking factor for this attempt
    SELECT exam_id
    INTO   v_exam_id
    FROM   STUDENT_EXAM
    WHERE  attempt_id = p_attempt_id;

    SELECT negative_marking
    INTO   v_negative_marking
    FROM   EXAMS
    WHERE  exam_id = v_exam_id;

    -- Sum marks for correctly answered questions
    SELECT COALESCE(SUM(q.marks), 0)
    INTO   v_correct_score
    FROM   STUDENT_RESPONSE sr
    JOIN   OPTIONS    o ON sr.selected_option_id = o.option_id
    JOIN   QUESTIONS  q ON sr.question_id        = q.question_id
    WHERE  sr.attempt_id = p_attempt_id
      AND  o.is_correct  = TRUE;

    -- Sum penalties for incorrectly answered questions
    SELECT COALESCE(SUM(v_negative_marking), 0)
    INTO   v_negative_score
    FROM   STUDENT_RESPONSE sr
    JOIN   OPTIONS    o ON sr.selected_option_id = o.option_id
    JOIN   QUESTIONS  q ON sr.question_id        = q.question_id
    WHERE  sr.attempt_id = p_attempt_id
      AND  o.is_correct  = FALSE;

    SET p_total_score = v_correct_score - v_negative_score;
END //
DELIMITER ;



-- PROCEDURE: AssignRanks  (uses EXPLICIT CURSOR)
-- Iterates over all completed attempts for an exam ordered by
-- score DESC and writes the rank into RESULTS.
-- Usage : CALL AssignRanks(1);

DELIMITER //
DROP PROCEDURE IF EXISTS AssignRanks //
CREATE PROCEDURE AssignRanks(IN p_exam_id INT)
BEGIN
    DECLARE v_attempt_id INT;
    DECLARE v_rank       INT DEFAULT 1;
    DECLARE v_done       INT DEFAULT FALSE;

    -- Cursor: completed attempts for this exam, best score first
    DECLARE rank_cursor CURSOR FOR
        SELECT r.attempt_id
        FROM   RESULTS      r
        JOIN   STUDENT_EXAM se ON r.attempt_id = se.attempt_id
        WHERE  se.exam_id = p_exam_id
        ORDER  BY r.score DESC;

    DECLARE CONTINUE HANDLER FOR NOT FOUND SET v_done = TRUE;

    OPEN rank_cursor;

    rank_loop: LOOP
        FETCH rank_cursor INTO v_attempt_id;
        IF v_done THEN
            LEAVE rank_loop;
        END IF;

        UPDATE RESULTS
        SET    student_rank = v_rank
        WHERE  attempt_id   = v_attempt_id;

        SET v_rank = v_rank + 1;
    END LOOP rank_loop;

    CLOSE rank_cursor;
END //
DELIMITER ;



-- PROCEDURE: GetStudentReport  (uses CURSOR)
-- Returns a per-student summary across all exams they attempted.
-- Usage : CALL GetStudentReport(2);

DELIMITER //
DROP PROCEDURE IF EXISTS GetStudentReport //
CREATE PROCEDURE GetStudentReport(IN p_user_id INT)
BEGIN
    DECLARE v_attempt_id INT;
    DECLARE v_subject    VARCHAR(100);
    DECLARE v_score      DECIMAL(10,2);
    DECLARE v_rank       INT;
    DECLARE v_status     VARCHAR(50);
    DECLARE v_done       INT DEFAULT FALSE;

    -- Cursor: all completed attempts by this student
    DECLARE student_cursor CURSOR FOR
        SELECT se.attempt_id,
               e.subject,
               r.score,
               r.student_rank,
               r.result_status
        FROM   STUDENT_EXAM se
        JOIN   EXAMS   e ON se.exam_id    = e.exam_id
        JOIN   RESULTS r ON se.attempt_id = r.attempt_id
        WHERE  se.user_id = p_user_id
          AND  se.status  = 'COMPLETED'
        ORDER  BY e.subject;

    DECLARE CONTINUE HANDLER FOR NOT FOUND SET v_done = TRUE;

    -- Temporary table to collect the report rows
    DROP TEMPORARY TABLE IF EXISTS student_report;
    CREATE TEMPORARY TABLE student_report (
        subject      VARCHAR(100),
        score        DECIMAL(10,2),
        student_rank INT,
        result_status VARCHAR(50)
    );

    OPEN student_cursor;

    report_loop: LOOP
        FETCH student_cursor INTO v_attempt_id, v_subject, v_score, v_rank, v_status;
        IF v_done THEN
            LEAVE report_loop;
        END IF;

        INSERT INTO student_report VALUES (v_subject, v_score, v_rank, v_status);
    END LOOP report_loop;

    CLOSE student_cursor;

    -- Return the collected report
    SELECT * FROM student_report;

    DROP TEMPORARY TABLE IF EXISTS student_report;
END //
DELIMITER ;



-- PROCEDURE: SubmitExam
-- Single atomic call: marks attempt COMPLETED, calculates
-- score (via CalculateTotalScore), then assigns ranks for
-- the whole exam.
-- Usage : CALL SubmitExam(1);

DELIMITER //
DROP PROCEDURE IF EXISTS SubmitExam //
CREATE PROCEDURE SubmitExam(IN p_attempt_id INT)
BEGIN
    DECLARE v_exam_id INT;

    -- Mark attempt as completed (this fires AfterExamSubmission trigger)
    UPDATE STUDENT_EXAM
    SET    status   = 'COMPLETED',
           end_time = NOW()
    WHERE  attempt_id = p_attempt_id;

    -- Re-rank all students for this exam
    SELECT exam_id INTO v_exam_id
    FROM   STUDENT_EXAM
    WHERE  attempt_id = p_attempt_id;

    CALL AssignRanks(v_exam_id);
END //
DELIMITER ;



-- SECTION 4: TRIGGERS



-- TRIGGER: BeforeExamAttempt  (BEFORE INSERT on STUDENT_EXAM)
-- Blocks a student from registering for an exam whose
-- exam_date has already passed.

DELIMITER //
DROP TRIGGER IF EXISTS BeforeExamAttempt //
CREATE TRIGGER BeforeExamAttempt
BEFORE INSERT ON STUDENT_EXAM
FOR EACH ROW
BEGIN
    DECLARE v_exam_date DATETIME;

    SELECT exam_date
    INTO   v_exam_date
    FROM   EXAMS
    WHERE  exam_id = NEW.exam_id;

    IF v_exam_date < NOW() THEN
        SIGNAL SQLSTATE '45000'
        SET MESSAGE_TEXT = 'Registration closed: exam date has already passed.';
    END IF;
END //
DELIMITER ;



-- TRIGGER: AfterExamSubmission  (original, kept intact)
-- Automatically inserts a row into RESULTS when an attempt
-- transitions to COMPLETED status.

DELIMITER //
DROP TRIGGER IF EXISTS AfterExamSubmission //
CREATE TRIGGER AfterExamSubmission
AFTER UPDATE ON STUDENT_EXAM
FOR EACH ROW
BEGIN
    DECLARE v_score DECIMAL(10,2);

    IF NEW.status = 'COMPLETED' AND OLD.status != 'COMPLETED' THEN
        CALL CalculateTotalScore(NEW.attempt_id, v_score);

        INSERT INTO RESULTS (attempt_id, score, result_status)
        VALUES (NEW.attempt_id, v_score, 'AUTO_GENERATED');
    END IF;
END //
DELIMITER ;



-- TRIGGER: AfterResultInsert  (AFTER INSERT on RESULTS)
-- Sets result_status to PASS or FAIL based on whether the
-- student scored >= 40% of total_marks.

DELIMITER //
DROP TRIGGER IF EXISTS AfterResultInsert //
CREATE TRIGGER AfterResultInsert
AFTER INSERT ON RESULTS
FOR EACH ROW
BEGIN
    DECLARE v_total_marks INT;

    SELECT e.total_marks
    INTO   v_total_marks
    FROM   EXAMS        e
    JOIN   STUDENT_EXAM se ON e.exam_id = se.exam_id
    WHERE  se.attempt_id = NEW.attempt_id;

    UPDATE RESULTS
    SET    result_status = IF(NEW.score >= v_total_marks * 0.40, 'PASS', 'FAIL')
    WHERE  result_id     = NEW.result_id;
END //
DELIMITER ;



-- TRIGGER: AfterProctoringUpdate  (AFTER UPDATE on PROCTORING_LOG)
-- Automatically flags an attempt as suspicious when
-- tab_switch_count exceeds 5.

DELIMITER //
DROP TRIGGER IF EXISTS AfterProctoringUpdate //
CREATE TRIGGER AfterProctoringUpdate
AFTER UPDATE ON PROCTORING_LOG
FOR EACH ROW
BEGIN
    IF NEW.tab_switch_count > 5 AND NEW.suspicious_flag = FALSE THEN
        UPDATE PROCTORING_LOG
        SET    suspicious_flag = TRUE
        WHERE  log_id          = NEW.log_id;
    END IF;
END //
DELIMITER ;



-- TRIGGER: AfterProctoringInsert  (AFTER INSERT on PROCTORING_LOG)
-- Creates the initial proctoring log entry when a student
-- starts an exam (triggered from application layer).
-- Also flags immediately if somehow tab switches already > 5.

DELIMITER //
DROP TRIGGER IF EXISTS AfterProctoringInsert //
CREATE TRIGGER AfterProctoringInsert
AFTER INSERT ON PROCTORING_LOG
FOR EACH ROW
BEGIN
    IF NEW.tab_switch_count > 5 THEN
        UPDATE PROCTORING_LOG
        SET    suspicious_flag = TRUE
        WHERE  log_id          = NEW.log_id;
    END IF;
END //
DELIMITER ;



-- SECTION 5: SEED DATA — ROLES

INSERT IGNORE INTO ROLES (role_id, role_name) VALUES
    (1, 'Admin'),
    (2, 'Student');

SELECT * FROM ROLES;



-- SECTION 6: SEED DATA — EXAMS


INSERT IGNORE INTO EXAMS (exam_id, subject, exam_date, duration_minutes, total_marks, negative_marking)
VALUES
    (1, 'DBMS',               NOW(), 30, 50, 0.50),
    (2, 'Operating Systems',  NOW(), 25, 50, 0.50),
    (3, 'Computer Networks',  NOW(), 30, 50, 0.25),
    (4, 'Data Structures',    NOW(), 35, 50, 0.50),
    (5, 'Mathematics',        NOW(), 40, 50, 0.25);

SELECT * FROM EXAMS;


-- SECTION 7: SEED DATA — QUESTIONS & OPTIONS
-- (Cleaned: drop any partial inserts, then insert final set)


SET SQL_SAFE_UPDATES = 0;
SET FOREIGN_KEY_CHECKS = 0;
DELETE FROM OPTIONS;
DELETE FROM QUESTIONS;
SET FOREIGN_KEY_CHECKS = 1;
SET SQL_SAFE_UPDATES = 1;


-- QUESTIONS — all 50

INSERT IGNORE INTO QUESTIONS
    (question_id, exam_id, question_text, question_type, difficulty, topic, marks)
VALUES

-- DBMS (Exam 1)
(1,  1, 'Which of the following is not a transaction state?',          'MCQ', 'EASY',   'Transactions', 5),
(2,  1, 'What does ACID stand for in DBMS?',                           'MCQ', 'MEDIUM', 'Transactions', 5),
(3,  1, 'Which normal form deals with multivalued dependency?',         'MCQ', 'HARD',   'Normalization', 5),
(4,  1, 'In an ER diagram, an entity is represented by:',              'MCQ', 'EASY',   'ER Modeling', 5),
(5,  1, 'Which of the following is a DDL command?',                    'MCQ', 'EASY',   'SQL Commands', 5),
(6,  1, 'Which key uniquely identifies a tuple in a relation?',        'MCQ', 'EASY',   'Keys', 5),
(7,  1, 'Which join returns matching rows from both tables?',          'MCQ', 'MEDIUM', 'Joins', 5),
(8,  1, 'Which command removes all rows from a table quickly?',        'MCQ', 'MEDIUM', 'Commands', 5),
(9,  1, 'A weak entity depends on which type of entity?',              'MCQ', 'MEDIUM', 'ER Modeling', 5),
(10, 1, 'Which indexing method is commonly used in databases?',        'MCQ', 'HARD',   'Indexing', 5),

-- Operating Systems (Exam 2)
(11, 2, 'What is the primary objective of an operating system?',       'MCQ', 'EASY',   'Basics', 5),
(12, 2, 'Which scheduling algorithm executes process first come first serve?', 'MCQ', 'MEDIUM', 'Scheduling', 5),
(13, 2, 'Which memory is volatile?',                                   'MCQ', 'EASY',   'Memory', 5),
(14, 2, 'Which scheduling algorithm uses time quantum?',               'MCQ', 'MEDIUM', 'Scheduling', 5),
(15, 2, 'Deadlock occurs when:',                                       'MCQ', 'HARD',   'Deadlock', 5),
(16, 2, 'Which memory management technique causes fragmentation?',     'MCQ', 'MEDIUM', 'Memory', 5),
(17, 2, 'Linux is an example of:',                                     'MCQ', 'EASY',   'OS Types', 5),
(18, 2, 'Which system call creates a new process in UNIX?',            'MCQ', 'MEDIUM', 'Processes', 5),
(19, 2, 'Thrashing occurs due to:',                                    'MCQ', 'HARD',   'Memory', 5),
(20, 2, 'Which of the following is not an OS?',                        'MCQ', 'EASY',   'Basics', 5),

-- Computer Networks (Exam 3)
(21, 3, 'Which device connects different networks?',                   'MCQ', 'EASY',   'Networking Devices', 5),
(22, 3, 'What does IP stand for?',                                     'MCQ', 'EASY',   'IP Addressing', 5),
(23, 3, 'Which layer handles routing?',                                'MCQ', 'MEDIUM', 'OSI Model', 5),
(24, 3, 'HTTP works on which layer?',                                  'MCQ', 'MEDIUM', 'Protocols', 5),
(25, 3, 'Which protocol is connection-oriented?',                      'MCQ', 'MEDIUM', 'Protocols', 5),
(26, 3, 'What is the default port of HTTP?',                           'MCQ', 'EASY',   'Ports', 5),
(27, 3, 'Which topology uses a central hub?',                          'MCQ', 'EASY',   'Topology', 5),
(28, 3, 'DNS translates domain names into:',                           'MCQ', 'EASY',   'DNS', 5),
(29, 3, 'Which protocol is used for email transfer?',                  'MCQ', 'MEDIUM', 'Protocols', 5),
(30, 3, 'Firewall is used for:',                                       'MCQ', 'EASY',   'Security', 5),

-- Data Structures (Exam 4)
(31, 4, 'Which data structure follows FIFO?',                          'MCQ', 'EASY',   'Queue', 5),
(32, 4, 'Which data structure follows LIFO?',                          'MCQ', 'EASY',   'Stack', 5),
(33, 4, 'Binary search works on:',                                     'MCQ', 'MEDIUM', 'Searching', 5),
(34, 4, 'Which traversal uses Root Left Right?',                       'MCQ', 'MEDIUM', 'Trees', 5),
(35, 4, 'Which data structure is used in recursion?',                  'MCQ', 'EASY',   'Stack', 5),
(36, 4, 'What is the worst case complexity of linear search?',         'MCQ', 'MEDIUM', 'Searching', 5),
(37, 4, 'Heap is a:',                                                  'MCQ', 'MEDIUM', 'Trees', 5),
(38, 4, 'Which structure uses nodes and pointers?',                    'MCQ', 'EASY',   'Linked List', 5),
(39, 4, 'DFS uses which data structure?',                              'MCQ', 'MEDIUM', 'Graphs', 5),
(40, 4, 'Which sorting algorithm is fastest on average?',              'MCQ', 'HARD',   'Sorting', 5),

-- Mathematics (Exam 5)
(41, 5, 'What is derivative of x^2?',                                  'MCQ', 'EASY',   'Calculus', 5),
(42, 5, 'Value of pi approximately equals?',                           'MCQ', 'EASY',   'Basics', 5),
(43, 5, 'What is determinant of identity matrix?',                     'MCQ', 'MEDIUM', 'Matrices', 5),
(44, 5, 'Integral of 1 dx is:',                                        'MCQ', 'MEDIUM', 'Calculus', 5),
(45, 5, 'What is 7 factorial?',                                        'MCQ', 'MEDIUM', 'Factorial', 5),
(46, 5, 'Which theorem is used in right triangle?',                    'MCQ', 'EASY',   'Geometry', 5),
(47, 5, 'log(1)= ?',                                                   'MCQ', 'EASY',   'Logarithms', 5),
(48, 5, 'What is probability value range?',                            'MCQ', 'MEDIUM', 'Probability', 5),
(49, 5, 'What is 15% of 200?',                                         'MCQ', 'EASY',   'Arithmetic', 5),
(50, 5, 'Matrix with equal rows and columns is called?',               'MCQ', 'EASY',   'Matrices', 5);


-- ---------------------------------------------------------
-- OPTIONS — all 200 (4 per question)

INSERT INTO OPTIONS (question_id, option_text, is_correct) VALUES

-- DBMS
(1,  'Active',                                          FALSE),
(1,  'Partially committed',                             FALSE),
(1,  'Failed',                                          FALSE),
(1,  'Compensated',                                     TRUE),

(2,  'Atomicity, Consistency, Isolation, Durability',   TRUE),
(2,  'Atomicity, Concurrency, Isolation, Durability',   FALSE),
(2,  'Automatic, Consistency, Isolation, Durability',   FALSE),
(2,  'Atomicity, Consistency, Integration, Durability', FALSE),

(3,  '1NF',                                            FALSE),
(3,  '2NF',                                            FALSE),
(3,  '3NF',                                            FALSE),
(3,  '4NF',                                            TRUE),

(4,  'Rectangle',                                      TRUE),
(4,  'Ellipse',                                        FALSE),
(4,  'Diamond',                                        FALSE),
(4,  'Circle',                                         FALSE),

(5,  'SELECT',                                         FALSE),
(5,  'INSERT',                                         FALSE),
(5,  'CREATE',                                         TRUE),
(5,  'UPDATE',                                         FALSE),

(6,  'Foreign Key',                                    FALSE),
(6,  'Primary Key',                                    TRUE),
(6,  'Candidate Key',                                  FALSE),
(6,  'Super Key',                                      FALSE),

(7,  'INNER JOIN',                                     TRUE),
(7,  'OUTER JOIN',                                     FALSE),
(7,  'LEFT JOIN',                                      FALSE),
(7,  'RIGHT JOIN',                                     FALSE),

(8,  'DELETE',                                         FALSE),
(8,  'REMOVE',                                         FALSE),
(8,  'TRUNCATE',                                       TRUE),
(8,  'DROP',                                           FALSE),

(9,  'Strong Entity',                                  TRUE),
(9,  'Attribute',                                      FALSE),
(9,  'Relationship',                                   FALSE),
(9,  'Tuple',                                          FALSE),

(10, 'B-Tree',                                         TRUE),
(10, 'Graph',                                          FALSE),
(10, 'Linked List',                                    FALSE),
(10, 'Stack',                                          FALSE),

-- Operating Systems
(11, 'Efficient use of hardware',                      TRUE),
(11, 'Gaming',                                         FALSE),
(11, 'Programming only',                               FALSE),
(11, 'Internet browsing',                              FALSE),

(12, 'FCFS',                                           TRUE),
(12, 'SJF',                                            FALSE),
(12, 'Round Robin',                                    FALSE),
(12, 'Priority',                                       FALSE),

(13, 'RAM',                                            TRUE),
(13, 'ROM',                                            FALSE),
(13, 'Hard Disk',                                      FALSE),
(13, 'SSD',                                            FALSE),

(14, 'Round Robin',                                    TRUE),
(14, 'FCFS',                                           FALSE),
(14, 'SJF',                                            FALSE),
(14, 'Priority',                                       FALSE),

(15, 'Processes wait forever',                         TRUE),
(15, 'CPU overload',                                   FALSE),
(15, 'Low memory',                                     FALSE),
(15, 'Fast execution',                                 FALSE),

(16, 'Paging',                                         FALSE),
(16, 'Segmentation',                                   TRUE),
(16, 'Virtual Memory',                                 FALSE),
(16, 'Caching',                                        FALSE),

(17, 'Open Source OS',                                 TRUE),
(17, 'Compiler',                                       FALSE),
(17, 'Database',                                       FALSE),
(17, 'Application',                                    FALSE),

(18, 'fork()',                                         TRUE),
(18, 'exec()',                                         FALSE),
(18, 'wait()',                                         FALSE),
(18, 'exit()',                                         FALSE),

(19, 'Excessive paging',                               TRUE),
(19, 'CPU overheating',                                FALSE),
(19, 'Virus attack',                                   FALSE),
(19, 'Power failure',                                  FALSE),

(20, 'Oracle',                                         TRUE),
(20, 'Windows',                                        FALSE),
(20, 'Linux',                                          FALSE),
(20, 'macOS',                                          FALSE),

-- Computer Networks
(21, 'Router',                                         TRUE),
(21, 'Switch',                                         FALSE),
(21, 'Hub',                                            FALSE),
(21, 'Repeater',                                       FALSE),

(22, 'Internet Protocol',                              TRUE),
(22, 'Internal Process',                               FALSE),
(22, 'Internet Process',                               FALSE),
(22, 'Internal Protocol',                              FALSE),

(23, 'Network Layer',                                  TRUE),
(23, 'Transport Layer',                                FALSE),
(23, 'Session Layer',                                  FALSE),
(23, 'Physical Layer',                                 FALSE),

(24, 'Application Layer',                              TRUE),
(24, 'Transport Layer',                                FALSE),
(24, 'Data Link Layer',                                FALSE),
(24, 'Physical Layer',                                 FALSE),

(25, 'TCP',                                            TRUE),
(25, 'UDP',                                            FALSE),
(25, 'IP',                                             FALSE),
(25, 'FTP',                                            FALSE),

(26, '80',                                             TRUE),
(26, '21',                                             FALSE),
(26, '25',                                             FALSE),
(26, '110',                                            FALSE),

(27, 'Star Topology',                                  TRUE),
(27, 'Ring Topology',                                  FALSE),
(27, 'Bus Topology',                                   FALSE),
(27, 'Mesh Topology',                                  FALSE),

(28, 'IP Addresses',                                   TRUE),
(28, 'MAC Addresses',                                  FALSE),
(28, 'URLs',                                           FALSE),
(28, 'Ports',                                          FALSE),

(29, 'SMTP',                                           TRUE),
(29, 'HTTP',                                           FALSE),
(29, 'FTP',                                            FALSE),
(29, 'SNMP',                                           FALSE),

(30, 'Security',                                       TRUE),
(30, 'Routing',                                        FALSE),
(30, 'Switching',                                      FALSE),
(30, 'Encoding',                                       FALSE),

-- Data Structures
(31, 'Queue',                                          TRUE),
(31, 'Stack',                                          FALSE),
(31, 'Tree',                                           FALSE),
(31, 'Graph',                                          FALSE),

(32, 'Stack',                                          TRUE),
(32, 'Queue',                                          FALSE),
(32, 'Heap',                                           FALSE),
(32, 'Graph',                                          FALSE),

(33, 'Sorted Array',                                   TRUE),
(33, 'Unsorted Array',                                 FALSE),
(33, 'Linked List',                                    FALSE),
(33, 'Stack',                                          FALSE),

(34, 'Preorder',                                       TRUE),
(34, 'Inorder',                                        FALSE),
(34, 'Postorder',                                      FALSE),
(34, 'Level Order',                                    FALSE),

(35, 'Stack',                                          TRUE),
(35, 'Queue',                                          FALSE),
(35, 'Tree',                                           FALSE),
(35, 'Graph',                                          FALSE),

(36, 'O(n)',                                           TRUE),
(36, 'O(log n)',                                       FALSE),
(36, 'O(n log n)',                                     FALSE),
(36, 'O(1)',                                           FALSE),

(37, 'Complete Binary Tree',                           TRUE),
(37, 'Graph',                                          FALSE),
(37, 'Queue',                                          FALSE),
(37, 'Array',                                          FALSE),

(38, 'Linked List',                                    TRUE),
(38, 'Array',                                          FALSE),
(38, 'Stack',                                          FALSE),
(38, 'Queue',                                          FALSE),

(39, 'Stack',                                          TRUE),
(39, 'Queue',                                          FALSE),
(39, 'Array',                                          FALSE),
(39, 'Heap',                                           FALSE),

(40, 'Quick Sort',                                     TRUE),
(40, 'Bubble Sort',                                    FALSE),
(40, 'Selection Sort',                                 FALSE),
(40, 'Insertion Sort',                                 FALSE),

-- Mathematics
(41, '2x',                                             TRUE),
(41, 'x',                                              FALSE),
(41, 'x^2',                                            FALSE),
(41, '1',                                              FALSE),

(42, '3.14',                                           TRUE),
(42, '2.14',                                           FALSE),
(42, '4.13',                                           FALSE),
(42, '5.12',                                           FALSE),

(43, '1',                                              TRUE),
(43, '0',                                              FALSE),
(43, '-1',                                             FALSE),
(43, '2',                                              FALSE),

(44, 'x + C',                                          TRUE),
(44, '1',                                              FALSE),
(44, '0',                                              FALSE),
(44, 'x^2',                                            FALSE),

(45, '5040',                                           TRUE),
(45, '720',                                            FALSE),
(45, '120',                                            FALSE),
(45, '40320',                                          FALSE),

(46, 'Pythagoras Theorem',                             TRUE),
(46, 'Binomial Theorem',                               FALSE),
(46, 'Bayes Theorem',                                  FALSE),
(46, 'Newton Theorem',                                 FALSE),

(47, '0',                                              TRUE),
(47, '1',                                              FALSE),
(47, '10',                                             FALSE),
(47, 'Infinity',                                       FALSE),

(48, '0 to 1',                                         TRUE),
(48, '0 to 10',                                        FALSE),
(48, '-1 to 1',                                        FALSE),
(48, '1 to 100',                                       FALSE),

(49, '30',                                             TRUE),
(49, '20',                                             FALSE),
(49, '15',                                             FALSE),
(49, '40',                                             FALSE),

(50, 'Square Matrix',                                  TRUE),
(50, 'Diagonal Matrix',                                FALSE),
(50, 'Row Matrix',                                     FALSE),
(50, 'Column Matrix',                                  FALSE);



-- SECTION 8: VERIFICATION SELECTS

SELECT * FROM EXAMS;
SELECT * FROM USERS;
SELECT COUNT(*) AS total_questions FROM QUESTIONS;
SELECT COUNT(*) AS total_options   FROM OPTIONS;
