import mysql.connector

def get_db_connection():
    try:
        connection = mysql.connector.connect(
            host="localhost",
            user="root",
            password="Mysha#1257",   # your MySQL password
            database="smart_exam"
        )
        return connection
    except Exception as e:
        print(f"Database connection failed: {e}")
        return None



