-- Smart Examination & Proctoring Management System Schema

CREATE DATABASE IF NOT EXISTS smart_exam;
USE smart_exam;

-- 1. ROLES
CREATE TABLE IF NOT EXISTS ROLES(
    role_id INT PRIMARY KEY AUTO_INCREMENT,
    role_name VARCHAR(50) NOT NULL UNIQUE
);

-- 2. USERS
CREATE TABLE IF NOT EXISTS USERS(
    user_id INT PRIMARY KEY AUTO_INCREMENT,
    name VARCHAR(100) NOT NULL,
    email VARCHAR(100) UNIQUE NOT NULL,
    password VARCHAR(255) NOT NULL,
    role_id INT,
    FOREIGN KEY (role_id) REFERENCES ROLES(role_id) ON DELETE SET NULL
);

-- 3. EXAMS
CREATE TABLE IF NOT EXISTS EXAMS(
    exam_id INT PRIMARY KEY AUTO_INCREMENT,
    subject VARCHAR(100) NOT NULL,
    exam_date DATETIME NOT NULL,
    duration_minutes INT NOT NULL,
    total_marks INT NOT NULL,
    negative_marking DECIMAL(5,2) DEFAULT 0.0 CHECK (negative_marking >= 0)
);

-- 4. QUESTIONS
CREATE TABLE IF NOT EXISTS QUESTIONS(
    question_id INT PRIMARY KEY AUTO_INCREMENT,
    exam_id INT,
    question_text TEXT NOT NULL,
    question_type VARCHAR(50) NOT NULL DEFAULT 'MCQ',
    difficulty VARCHAR(50) CHECK (difficulty IN ('EASY', 'MEDIUM', 'HARD')),
    topic VARCHAR(100),
    marks INT NOT NULL CHECK (marks > 0),
    FOREIGN KEY (exam_id) REFERENCES EXAMS(exam_id) ON DELETE CASCADE
);

-- 5. OPTIONS
CREATE TABLE IF NOT EXISTS OPTIONS(
    option_id INT PRIMARY KEY AUTO_INCREMENT,
    question_id INT,
    option_text TEXT NOT NULL,
    is_correct BOOLEAN DEFAULT FALSE,
    FOREIGN KEY (question_id) REFERENCES QUESTIONS(question_id) ON DELETE CASCADE
);

-- 6. STUDENT_EXAM
CREATE TABLE IF NOT EXISTS STUDENT_EXAM(
    attempt_id INT PRIMARY KEY AUTO_INCREMENT,
    user_id INT,
    exam_id INT,
    start_time DATETIME,
    end_time DATETIME,
    status VARCHAR(50) DEFAULT 'IN_PROGRESS' CHECK (status IN ('IN_PROGRESS', 'COMPLETED', 'ABORTED')),
    UNIQUE KEY user_exam_unique (user_id, exam_id),
    FOREIGN KEY (user_id) REFERENCES USERS(user_id) ON DELETE CASCADE,
    FOREIGN KEY (exam_id) REFERENCES EXAMS(exam_id) ON DELETE CASCADE
);

-- 7. STUDENT_RESPONSE
CREATE TABLE IF NOT EXISTS STUDENT_RESPONSE(
    response_id INT PRIMARY KEY AUTO_INCREMENT,
    attempt_id INT,
    question_id INT,
    selected_option_id INT,
    response_time DATETIME DEFAULT CURRENT_TIMESTAMP,
    FOREIGN KEY (attempt_id) REFERENCES STUDENT_EXAM(attempt_id) ON DELETE CASCADE,
    FOREIGN KEY (question_id) REFERENCES QUESTIONS(question_id) ON DELETE CASCADE,
    FOREIGN KEY (selected_option_id) REFERENCES OPTIONS(option_id) ON DELETE SET NULL
);

-- 8. PROCTORING_LOG
CREATE TABLE IF NOT EXISTS PROCTORING_LOG(
    log_id INT PRIMARY KEY AUTO_INCREMENT,
    attempt_id INT,
    login_time DATETIME DEFAULT CURRENT_TIMESTAMP,
    logout_time DATETIME,
    tab_switch_count INT DEFAULT 0 CHECK (tab_switch_count >= 0),
    suspicious_flag BOOLEAN DEFAULT FALSE,
    FOREIGN KEY (attempt_id) REFERENCES STUDENT_EXAM(attempt_id) ON DELETE CASCADE
);

-- 9. RESULTS
CREATE TABLE IF NOT EXISTS RESULTS(
    result_id INT PRIMARY KEY AUTO_INCREMENT,
    attempt_id INT,
    score DECIMAL(10,2),
    rank INT,
    result_status VARCHAR(50),
    FOREIGN KEY (attempt_id) REFERENCES STUDENT_EXAM(attempt_id) ON DELETE CASCADE
);

-- ==========================================
-- STORED PROCEDURE: CalculateTotalScore
-- ==========================================
DELIMITER //
DROP PROCEDURE IF EXISTS CalculateTotalScore //
CREATE PROCEDURE CalculateTotalScore(IN p_attempt_id INT, OUT p_total_score DECIMAL(10,2))
BEGIN
    DECLARE v_correct_score DECIMAL(10,2) DEFAULT 0;
    DECLARE v_negative_score DECIMAL(10,2) DEFAULT 0;
    DECLARE v_negative_marking DECIMAL(5,2) DEFAULT 0;
    DECLARE v_exam_id INT;

    -- Get Exam ID and Negative Marking for this attempt
    SELECT exam_id INTO v_exam_id FROM STUDENT_EXAM WHERE attempt_id = p_attempt_id;
    SELECT negative_marking INTO v_negative_marking FROM EXAMS WHERE exam_id = v_exam_id;

    -- Calculate marks for correctly answered questions
    SELECT COALESCE(SUM(q.marks), 0) INTO v_correct_score
    FROM STUDENT_RESPONSE sr
    JOIN OPTIONS o ON sr.selected_option_id = o.option_id
    JOIN QUESTIONS q ON sr.question_id = q.question_id
    WHERE sr.attempt_id = p_attempt_id AND o.is_correct = TRUE;
    
    -- Calculate penalty for incorrectly answered questions
    SELECT COALESCE(SUM(v_negative_marking), 0) INTO v_negative_score
    FROM STUDENT_RESPONSE sr
    JOIN OPTIONS o ON sr.selected_option_id = o.option_id
    JOIN QUESTIONS q ON sr.question_id = q.question_id
    WHERE sr.attempt_id = p_attempt_id AND o.is_correct = FALSE;

    -- Final Score
    SET p_total_score = v_correct_score - v_negative_score;
END //
DELIMITER ;

-- ==========================================
-- TRIGGER: AfterExamSubmission
-- ==========================================
DELIMITER //
DROP TRIGGER IF EXISTS AfterExamSubmission //
CREATE TRIGGER AfterExamSubmission
AFTER UPDATE ON STUDENT_EXAM
FOR EACH ROW
BEGIN
    DECLARE v_score DECIMAL(10,2);
    
    -- Check if status changed to 'COMPLETED'
    IF NEW.status = 'COMPLETED' AND OLD.status != 'COMPLETED' THEN
        -- Call stored procedure to get total score
        CALL CalculateTotalScore(NEW.attempt_id, v_score);
        
        -- Insert into RESULTS table automatically
        INSERT INTO RESULTS (attempt_id, score, result_status)
        VALUES (NEW.attempt_id, v_score, 'AUTO_GENERATED');
    END IF;
END //
DELIMITER ;

-- ==========================================
-- DEFAULT INSERTS (ROLES)
-- ==========================================
INSERT IGNORE INTO ROLES (role_id, role_name) VALUES 
(1, 'Admin'), 
(2, 'Student'), 
(3, 'Proctor');
