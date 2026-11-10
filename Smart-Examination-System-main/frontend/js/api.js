const API_BASE = 'http://localhost:5000/api';

function getToken() {
    return localStorage.getItem('token');
}

function getHeaders() {
    return {
        'Content-Type': 'application/json',
        'Authorization': `Bearer ${getToken()}`
    };
}

function showMsg(id, msg, isError = false) {
    const el = document.getElementById(id);
    if(el) {
        el.textContent = msg;
        el.className = `alert ${isError ? 'error' : 'success'}`;
    }
}

function logout() {
    localStorage.removeItem('token');
    localStorage.removeItem('role');
    localStorage.removeItem('name');
    window.location.href = 'index.html';
}

function checkAuth(expectedRole) {
    const token = getToken();
    const role = localStorage.getItem('role');
    if (!token) {
        window.location.href = 'index.html';
        return false;
    }
    if (expectedRole && role !== expectedRole) {
        alert('Unauthorized access');
        window.location.href = 'index.html';
        return false;
    }
    const userDisplay = document.getElementById('userNameDisplay');
    if (userDisplay) {
        userDisplay.textContent = localStorage.getItem('name');
    }
    return true;
}
