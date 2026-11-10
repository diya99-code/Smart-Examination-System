# Smart Examination & Proctoring Management System

A robust, full-stack application built for a DBMS lab setting, designed with a premium frontend and a rigorous backend integrating advanced MySQL database logic.

## 🛠 Tech Stack
- **Database**: MySQL (Features: Constraints, Foreign Keys, Stored Procedure, Trigger)
- **Backend API**: Python (Flask, PyJWT, MySQL-Connector)
- **Frontend**: Vanilla HTML5, CSS3 (Glassmorphism design), Vanilla JS (Fetch API)

## 📁 Project Structure

- `database/schema.sql` - Core database DDL (Schema, constraints, `CalculateTotalScore` procedure, `AfterExamSubmission` trigger, default Role inserts).
- `backend/` - The Python Flask API using strict transactional DB queries (`COMMIT`, `ROLLBACK`).
- `frontend/` - Beautiful, dynamic user layer capturing UI changes, interactions, and strict Role-Based routing.

## 🚀 Setup & Execution

### 1. Database Setup
Ensure you have a MySQL server running locally.
1. Run MySQL shell or workbench.
2. Source the `database/schema.sql` script:
   ```sql
   SOURCE database/schema.sql;
   ```
   *(This creates `exam_db`, all tables, logic, and base roles).*

### 2. Backend API
1. Navigate to `backend/`:
   ```bash
   cd backend
   ```
2. Install Python dependencies:
   ```bash
   python -m pip install -r requirements.txt
   ```
3. Run the development server:
   ```bash
   python app.py
   ```
*(Runs on http://localhost:5000)*

### 3. Frontend App
Open `frontend/index.html` in your browser. (Since it's pure HTML/JS using relative links and CORS is permitted by the backend, opening directly as a `file://` via your web browser is fine).

## 🧪 Demo Flow
1. **Sign Up**: Create an Admin, a Student, and a Proctor via `index.html`.
2. **Admin**: Log in as Admin. Create a new exam and add questions to it.
3. **Student**: Open a new private window and log in as Student. Ensure the exam is visible.
4. **Proctor**: Open a third window/split-screen and log in as Proctor. The active proctor log will auto-refresh.
5. **Taking the Exam**: Switch tabs while logged in as the Student. The frontend fires real-time `visibilitychange` events and updates the proctor log from *CLEAN* to **SUSPICIOUS**.
6. **Submission/Trigger Check**: Submit the exam. Our MySQL trigger (`AfterExamSubmission`) automatically captures the state change and calls the stored procedure (`CalculateTotalScore`) to evaluate exactly which answers matched the `is_correct` flags inside the `OPTIONS` table, outputting a calculated score to the `RESULTS` table.
