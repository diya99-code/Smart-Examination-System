from flask import Flask, jsonify, request
from flask_cors import CORS
from db import get_db_connection
import jwt
import datetime
from functools import wraps

app = Flask(__name__)
CORS(app)

app.config['SECRET_KEY'] = 'super_secret_jwt_key_for_dbms_lab'

# --------------------------
# TOKEN MIDDLEWARE
# --------------------------
def token_required(f):
    @wraps(f)
    def decorated(*args, **kwargs):
        token = request.headers.get('Authorization')

        if not token:
            return jsonify({'message': 'Token is missing'}), 401

        try:
            token = token.split(" ")[1]
            data = jwt.decode(token, app.config['SECRET_KEY'], algorithms=["HS256"])
        except Exception as e:
            return jsonify({'message': 'Token invalid', 'error': str(e)}), 401

        return f(data, *args, **kwargs)
    return decorated


# --------------------------
# HEALTH CHECK
# --------------------------
@app.route('/api/health')
def health():
    return jsonify({"status": "Server running"})


# --------------------------
# AUTH
# --------------------------
@app.route('/api/auth/register', methods=['POST'])
def register():
    data = request.json

    conn = get_db_connection()
    cursor = conn.cursor()

    try:
        role_id = data.get('role_id', 2)
        cursor.execute(
            "INSERT INTO USERS (name, email, password, role_id) VALUES (%s, %s, %s, %s)",
            (data['name'], data['email'], data['password'], role_id)
        )
        conn.commit()
        return jsonify({'message': 'User registered successfully'})
    except Exception as e:
        conn.rollback()
        return jsonify({'error': str(e)})
    finally:
        cursor.close()
        conn.close()


@app.route('/api/auth/login', methods=['POST'])
def login():
    data = request.json

    conn = get_db_connection()
    cursor = conn.cursor(dictionary=True)

    cursor.execute("""
        SELECT u.*, r.role_name 
        FROM USERS u 
        JOIN ROLES r ON u.role_id = r.role_id 
        WHERE email=%s AND password=%s
    """, (data['email'], data['password']))

    user = cursor.fetchone()

    if not user:
        return jsonify({'message': 'Invalid credentials'}), 401

    token = jwt.encode({
        'user_id': user['user_id'],
        'role': user['role_name'],
        'exp': datetime.datetime.utcnow() + datetime.timedelta(hours=24)
    }, app.config['SECRET_KEY'], algorithm="HS256")

    return jsonify({
        'token': token,
        'role': user['role_name'],
        'name': user['name']
    })


# --------------------------
# STUDENT ROUTES
# --------------------------

# ✅ FIXED: No auth required (for demo)
@app.route('/api/student/exams/available', methods=['GET'])
def get_available_exams():
    conn = get_db_connection()
    cursor = conn.cursor(dictionary=True)

    cursor.execute("SELECT * FROM EXAMS")
    exams = cursor.fetchall()

    cursor.close()
    conn.close()

    return jsonify(exams)


@app.route('/api/student/exams/<int:exam_id>/start', methods=['POST'])
@token_required
def start_exam(current_user, exam_id):
    conn = get_db_connection()
    cursor = conn.cursor(dictionary=True)

    try:
        user_id = current_user['user_id']
        
        # Check for existing attempts
        cursor.execute("SELECT attempt_id, status FROM STUDENT_EXAM WHERE user_id=%s AND exam_id=%s", (user_id, exam_id))
        existing = cursor.fetchone()
        
        if existing:
            if existing['status'] == 'COMPLETED':
                return jsonify({'error': 'You have already completed this exam.'}), 400
            else:
                # Resume exam
                return jsonify({'attempt_id': existing['attempt_id']})

        cursor.execute("""
            INSERT INTO STUDENT_EXAM (user_id, exam_id, start_time, status)
            VALUES (%s, %s, NOW(), 'IN_PROGRESS')
        """, (user_id, exam_id))

        attempt_id = cursor.lastrowid
        conn.commit()

        return jsonify({'attempt_id': attempt_id})
    except Exception as e:
        conn.rollback()
        return jsonify({'error': str(e)}), 400
    finally:
        cursor.close()
        conn.close()


@app.route('/api/student/exams/<int:exam_id>/questions', methods=['GET'])
def get_questions(exam_id):
    conn = get_db_connection()
    cursor = conn.cursor(dictionary=True)

    cursor.execute("SELECT * FROM QUESTIONS WHERE exam_id=%s", (exam_id,))
    questions = cursor.fetchall()

    for q in questions:
        cursor.execute(
            "SELECT option_id, option_text FROM OPTIONS WHERE question_id=%s",
            (q['question_id'],)
        )
        q['options'] = cursor.fetchall()

    cursor.close()
    conn.close()

    return jsonify(questions)


@app.route('/api/student/responses', methods=['POST'])
def save_response():
    data = request.json

    conn = get_db_connection()
    cursor = conn.cursor()

    try:
        cursor.execute("""
            INSERT INTO STUDENT_RESPONSE (attempt_id, question_id, selected_option_id)
            VALUES (%s, %s, %s)
        """, (data['attempt_id'], data['question_id'], data['selected_option_id']))

        conn.commit()
        return jsonify({'message': 'Saved'})
    except Exception as e:
        conn.rollback()
        return jsonify({'error': str(e)})
    finally:
        cursor.close()
        conn.close()


@app.route('/api/student/exams/<int:attempt_id>/submit', methods=['POST'])
def submit_exam(attempt_id):
    conn = get_db_connection()
    cursor = conn.cursor()

    try:
        cursor.execute("""
            UPDATE STUDENT_EXAM 
            SET status='COMPLETED', end_time=NOW()
            WHERE attempt_id=%s
        """, (attempt_id,))

        conn.commit()
        return jsonify({'message': 'Submitted'})
    except Exception as e:
        conn.rollback()
        return jsonify({'error': str(e)})
    finally:
        cursor.close()
        conn.close()


@app.route('/api/student/results')
@token_required
def get_results(current_user):
    conn = get_db_connection()
    cursor = conn.cursor(dictionary=True)

    cursor.execute("""
        SELECT r.score, e.subject, r.result_status
        FROM RESULTS r
        JOIN STUDENT_EXAM se ON r.attempt_id = se.attempt_id
        JOIN EXAMS e ON se.exam_id = e.exam_id
        WHERE se.user_id = %s
    """, (current_user['user_id'],))

    results = cursor.fetchall()

    cursor.close()
    conn.close()

    return jsonify(results)


# --------------------------
# ADMIN ROUTES
# --------------------------

@app.route('/api/admin/results', methods=['GET'])
@token_required
def get_all_results(current_user):
    if current_user['role'] != 'Admin':
        return jsonify({'error': 'Unauthorized'}), 403

    conn = get_db_connection()
    cursor = conn.cursor(dictionary=True)

    cursor.execute("""
        SELECT u.name as student_name, e.subject, r.score, r.result_status
        FROM RESULTS r
        JOIN STUDENT_EXAM se ON r.attempt_id = se.attempt_id
        JOIN USERS u ON se.user_id = u.user_id
        JOIN EXAMS e ON se.exam_id = e.exam_id
    """)

    results = cursor.fetchall()

    cursor.close()
    conn.close()

    return jsonify(results)

@app.route('/api/admin/exams', methods=['GET', 'POST'])
@token_required
def admin_exams(current_user):
    if current_user['role'] != 'Admin':
        return jsonify({'error': 'Unauthorized'}), 403

    conn = get_db_connection()
    cursor = conn.cursor(dictionary=True)

    if request.method == 'GET':
        cursor.execute("SELECT * FROM EXAMS")
        exams = cursor.fetchall()
        cursor.close()
        conn.close()
        return jsonify(exams)

    if request.method == 'POST':
        data = request.json
        try:
            cursor.execute("""
                INSERT INTO EXAMS (subject, exam_date, duration_minutes, total_marks, negative_marking)
                VALUES (%s, %s, %s, %s, %s)
            """, (data['subject'], data['exam_date'], data['duration_minutes'], data['total_marks'], data['negative_marking']))
            conn.commit()
            return jsonify({'message': 'Exam created successfully'})
        except Exception as e:
            conn.rollback()
            return jsonify({'error': str(e)}), 400
        finally:
            cursor.close()
            conn.close()

@app.route('/api/admin/exams/<int:exam_id>/questions', methods=['POST'])
@token_required
def admin_add_question(current_user, exam_id):
    if current_user['role'] != 'Admin':
        return jsonify({'error': 'Unauthorized'}), 403

    data = request.json
    conn = get_db_connection()
    cursor = conn.cursor()

    try:
        # Insert question
        cursor.execute("""
            INSERT INTO QUESTIONS (exam_id, question_text, question_type, difficulty, topic, marks)
            VALUES (%s, %s, 'MCQ', 'MEDIUM', 'General', %s)
        """, (exam_id, data['text'], data['marks']))
        
        question_id = cursor.lastrowid
        
        # Insert options
        for opt in data['options']:
            cursor.execute("""
                INSERT INTO OPTIONS (question_id, option_text, is_correct)
                VALUES (%s, %s, %s)
            """, (question_id, opt['text'], opt['is_correct']))
            
        conn.commit()
        return jsonify({'message': 'Question added successfully'})
    except Exception as e:
        conn.rollback()
        return jsonify({'error': str(e)}), 400
    finally:
        cursor.close()
        conn.close()

# --------------------------
# RUN
# --------------------------
if __name__ == '__main__':
    app.run(debug=True, port=5000)